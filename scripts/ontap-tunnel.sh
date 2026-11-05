#!/usr/bin/env bash
# Opens SSM port forwards from this Mac to both FSx for ONTAP management endpoints,
# so stacks/04-flexcache (ONTAP provider) can reach their private IPs:
#
#   localhost:8443  ->  FSx for ONTAP Origin management IP :443
#   localhost:9443  ->  FSx for ONTAP Cache  management IP :443 (over the origin <-> cache peering)
#
# Both go through the origin EC2 client (stack 03), so nothing is exposed to the
# internet and no bastion is needed. Leave it running in one terminal while you
# run ./tf.sh 04-flexcache plan/apply in another; Ctrl-C closes both tunnels.
#
# Needs: aws CLI v2, the Session Manager plugin, jq, and your AWS credentials
# (AWS_PROFILE or the default profile).
#   brew install awscli jq && brew install --cask session-manager-plugin
#
# Ports can be changed with ORIGIN_PORT / CACHE_PORT; then set the same values in
# stacks/04-flexcache/terraform.tfvars (origin_ontap_endpoint / cache_ontap_endpoint).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TF_BIN:-terraform}"
ORIGIN_PORT="${ORIGIN_PORT:-8443}"
CACHE_PORT="${CACHE_PORT:-9443}"

for cmd in aws session-manager-plugin jq "$TF"; do
  command -v "$cmd" >/dev/null || { echo "Missing '$cmd' (see the header of this script)."; exit 1; }
done

out() { "$TF" -chdir="$ROOT/stacks/$1" output -json "$2"; }

client="$(out 03-ec2 origin_client)" || { echo "No origin_client output: apply stacks/03-ec2 first."; exit 1; }
origin="$(out 02-fsxn origin)"       || { echo "No origin output: apply stacks/02-fsxn first."; exit 1; }
cache="$(out 02-fsxn cache)"         || cache=null

INSTANCE_ID="$(jq -r .instance_id <<<"$client")"
REGION="$(jq -r .region <<<"$client")"

tunnel() { # <local port> <remote ip>
  aws ssm start-session --region "$REGION" --target "$INSTANCE_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=$2,portNumber=443,localPortNumber=$1" &
}

trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM

ORIGIN_IP="$(jq -r .management_ip <<<"$origin")"
echo "Origin: localhost:$ORIGIN_PORT -> $ORIGIN_IP:443 via $INSTANCE_ID"
tunnel "$ORIGIN_PORT" "$ORIGIN_IP"

if [[ "$cache" != "null" ]]; then
  CACHE_IP="$(jq -r .management_ip <<<"$cache")"
  echo "Cache:  localhost:$CACHE_PORT -> $CACHE_IP:443 via $INSTANCE_ID"
  tunnel "$CACHE_PORT" "$CACHE_IP"
else
  echo "Cache:  no FSx for ONTAP Cache in the 02-fsxn state, skipped."
fi

wait
