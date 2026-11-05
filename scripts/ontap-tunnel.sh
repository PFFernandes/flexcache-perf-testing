#!/usr/bin/env bash
# SSH tunnel from this Mac to both FSx for ONTAP management endpoints, through
# the EC2 Instance Connect Endpoint and the helper EC2 (stack 03-helper):
#
#   localhost:8443  ->  FSx for ONTAP Origin management IP :443
#   localhost:9443  ->  FSx for ONTAP Cache  management IP :443 (over the peering)
#
# Usage:
#   ./scripts/ontap-tunnel.sh           keep the tunnel open (Ctrl-C to close) while
#                                       you run ./tf.sh 04-flexcache plan/apply elsewhere
#   ./scripts/ontap-tunnel.sh --check   open it, call GET /api/cluster on both FSx for
#                                       ONTAP with the fsxadmin secret, print the result, close
#
# Needs: aws CLI v2, ssh, jq (built into macOS 15+, else `brew install jq`) and AWS
# credentials (AWS_PROFILE). Ports: ORIGIN_PORT / CACHE_PORT (then also set
# origin_ontap_endpoint / cache_ontap_endpoint in stacks/04-flexcache/terraform.tfvars).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TF_BIN:-terraform}"
ORIGIN_PORT="${ORIGIN_PORT:-8443}"
CACHE_PORT="${CACHE_PORT:-9443}"
CHECK=false
[[ "${1:-}" == "--check" ]] && CHECK=true

for cmd in aws ssh ssh-keygen jq curl "$TF"; do
  command -v "$cmd" >/dev/null || { echo "Missing '$cmd' (see the header of this script)."; exit 1; }
done

out() { "$TF" -chdir="$ROOT/stacks/$1" output -json "$2" 2>/dev/null || echo null; }

helper="$(out 03-helper helper)"
[[ "$helper" == "null" ]] && { echo "No helper in the 03-helper state: run ./tf.sh 03-helper apply first."; exit 1; }
origin="$(out 02-fsxn origin)"
cache="$(out 02-fsxn cache)"
[[ "$origin" == "null" && "$cache" == "null" ]] && { echo "No FSx for ONTAP in the 02-fsxn state: run ./tf.sh 02-fsxn apply first."; exit 1; }

INSTANCE_ID="$(jq -r .instance_id <<<"$helper")"
REGION="$(jq -r .region <<<"$helper")"
EICE_ID="$(jq -r .eice_id <<<"$helper")"
OS_USER="$(jq -r .os_user <<<"$helper")"

# Port forwards for whichever side exists.
FORWARDS=()
if [[ "$origin" != "null" ]]; then
  ORIGIN_IP="$(jq -r .management_ip <<<"$origin")"
  FORWARDS+=(-L "$ORIGIN_PORT:$ORIGIN_IP:443")
  echo "Origin: localhost:$ORIGIN_PORT -> $ORIGIN_IP:443"
fi
if [[ "$cache" != "null" ]]; then
  CACHE_IP="$(jq -r .management_ip <<<"$cache")"
  FORWARDS+=(-L "$CACHE_PORT:$CACHE_IP:443")
  echo "Cache:  localhost:$CACHE_PORT -> $CACHE_IP:443"
fi
echo "Via:    $INSTANCE_ID ($REGION) through EICE $EICE_ID"

# Short-lived key: generated here, pushed with EC2 Instance Connect (valid 60 s,
# enough to log in), deleted on exit.
TMP="$(mktemp -d)"
SSH_PID=""
cleanup() {
  [[ -n "$SSH_PID" ]] && kill "$SSH_PID" 2>/dev/null || true
  rm -rf "${TMP:?}"
}
trap cleanup EXIT INT TERM
ssh-keygen -q -t ed25519 -N "" -f "$TMP/key"
aws ec2-instance-connect send-ssh-public-key --region "$REGION" --instance-id "$INSTANCE_ID" \
  --instance-os-user "$OS_USER" --ssh-public-key "file://$TMP/key.pub" >/dev/null

SSH=(ssh -i "$TMP/key" -N
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o "ProxyCommand=aws ec2-instance-connect open-tunnel --region $REGION --instance-id $INSTANCE_ID --instance-connect-endpoint-id $EICE_ID"
  "${FORWARDS[@]}" "$OS_USER@$INSTANCE_ID")

if ! $CHECK; then
  echo "Tunnel open. Ctrl-C to close."
  "${SSH[@]}"
  exit 0
fi

# --- --check: call the ONTAP REST API on both sides through the tunnel ----------
"${SSH[@]}" &
SSH_PID=$!

SECRET_ARN="$(out 02-fsxn fsxadmin_secret | jq -r .arn)"
SECRET_REGION="$(out 02-fsxn fsxadmin_secret | jq -r .region)"
CREDS="$(aws secretsmanager get-secret-value --region "$SECRET_REGION" --secret-id "$SECRET_ARN" \
  --query SecretString --output text)"
USER_PASS="$(jq -r '"\(.username):\(.password)"' <<<"$CREDS")"

check() { # <label> <local port>
  local body
  for _ in $(seq 1 20); do # wait for the tunnel (up to ~20 s)
    if body="$(curl -sk --max-time 5 -K - "https://localhost:$2/api/cluster?fields=name,version" \
      <<<"user = \"$USER_PASS\"")" && [[ -n "$body" ]]; then
      if jq -e .name >/dev/null 2>&1 <<<"$body"; then
        echo "  $1: OK  cluster $(jq -r .name <<<"$body"), ONTAP $(jq -r .version.full <<<"$body")"
      else
        echo "  $1: reached, but unexpected answer: $(head -c 300 <<<"$body")"
      fi
      return 0
    fi
    sleep 1
  done
  echo "  $1: FAILED - no answer on localhost:$2"
  return 1
}

echo "Checking the ONTAP REST API through the tunnel:"
rc=0
[[ "$origin" != "null" ]] && { check "FSx for ONTAP Origin" "$ORIGIN_PORT" || rc=1; }
[[ "$cache" != "null" ]] && { check "FSx for ONTAP Cache " "$CACHE_PORT" || rc=1; }
exit $rc
