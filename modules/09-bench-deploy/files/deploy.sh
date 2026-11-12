#!/usr/bin/env bash
# Runs on the OPERATOR MACHINE (Terraform local-exec in modules/09-bench-deploy).
# Packs bench/ and profiles/ from the repository, sends them to one EC2 client with SSM
# Run Command, waits and prints the client's output (files/remote.sh runs there).
# Exit code 0 only if the client reports success.
#
# Environment (set by Terraform):
#   ACTION        deploy | remove
#   REGION        region of the client
#   INSTANCE_ID   client instance ID
#   SIDE          origin | cache (for the log)
#   SOURCE_ROOT   repository root (deploy)
#   SOURCE_DIRS   folders to pack, space separated, relative to SOURCE_ROOT (deploy)
#   BUNDLE_HASH   hash of those files, computed by Terraform (deploy)
#   PACKAGES      extra dnf packages, comma separated (deploy, may be empty)
#   RUN_TESTS     1 = run the bench tests on the client (deploy)
#   REMOTE_SH     path of files/remote.sh
set -euo pipefail

: "${ACTION:?}" "${REGION:?}" "${INSTANCE_ID:?}" "${REMOTE_SH:?}"
SIDE="${SIDE:-client}"
CHUNK_BYTES=40000        # bundle bytes per SSM command (SSM limits the size of one command)
log() { echo "[bench-deploy $SIDE] $*"; }
b64() { base64 | tr -d '\n'; }   # one line on macOS and Linux

# 1. The client must exist and be online in SSM.
for i in $(seq 1 30); do
  ping="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$ping" == "Online" ]] && break
  if [[ $i -eq 30 ]]; then
    if [[ "$ACTION" == "remove" ]]; then
      log "client $INSTANCE_ID is not online in SSM (status: ${ping:-none}); nothing to remove"
      exit 0
    fi
    log "client $INSTANCE_ID is not online in SSM (status: ${ping:-none}). Is enable_ssm = true in stacks/03-ec2?"
    exit 1
  fi
  log "waiting for $INSTANCE_ID to be online in SSM (status: ${ping:-none})..."
  sleep 10
done

# 2. Send a command with SSM, wait, print its output. Fails the script if it fails.
#    Only base64 text and fixed words go into the JSON: no escaping needed.
send() { # <params.json> <comment> [quiet]
  local params="$1" comment="$2" quiet="${3:-}" cmd_id status err
  cmd_id="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript --comment "$comment" \
    --parameters "file://$params" --timeout-seconds 600 \
    --query Command.CommandId --output text)"
  [[ -n "$quiet" ]] || log "SSM command $cmd_id sent to $INSTANCE_ID ($comment); waiting..."
  while true; do
    status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
      --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Pending|InProgress|Delayed) sleep 3 ;;
      *) break ;;
    esac
  done
  if [[ -z "$quiet" || "$status" != "Success" ]]; then
    aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
      --query StandardOutputContent --output text
    err="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
      --query StandardErrorContent --output text)"
    [[ -n "$err" && "$err" != "None" ]] && echo "$err" >&2
  fi
  if [[ "$status" != "Success" ]]; then
    log "FAILED ($status). Full log: aws ssm get-command-invocation --region $REGION --command-id $cmd_id --instance-id $INSTANCE_ID"
    exit 1
  fi
}

REMOTE_B64="$(b64 < "$REMOTE_SH")"
PARAMS="$(mktemp)"
trap 'rm -f "$PARAMS"' EXIT

if [[ "$ACTION" != "deploy" ]]; then
  printf '{"executionTimeout":["300"],"commands":["set -euo pipefail","echo %s | base64 -d > /root/bench-remote.sh","bash /root/bench-remote.sh remove"]}' \
    "$REMOTE_B64" > "$PARAMS"
  send "$PARAMS" "bench $ACTION ($SIDE)"
  log "done"
  exit 0
fi

: "${SOURCE_ROOT:?}" "${SOURCE_DIRS:?}" "${BUNDLE_HASH:?}"
tar_opts=(--exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store')
if tar --version 2>/dev/null | grep -q bsdtar; then
  tar_opts+=(--no-mac-metadata --no-xattrs)   # no ._ files or macOS attributes on Linux
fi
# shellcheck disable=SC2086
BUNDLE_B64="$(COPYFILE_DISABLE=1 tar -C "$SOURCE_ROOT" "${tar_opts[@]}" -cf - $SOURCE_DIRS | gzip -9 | b64)"

commit="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
branch="$(git -C "$SOURCE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
dirty=false
# shellcheck disable=SC2086
[[ -n "$(git -C "$SOURCE_ROOT" status --porcelain -- $SOURCE_DIRS 2>/dev/null)" ]] && dirty=true
VERSION_B64="$(printf '{"commit":"%s","branch":"%s","uncommitted_changes":%s,"bundle_sha256":"%s","deployed":"%s"}\n' \
  "$commit" "$branch" "$dirty" "$BUNDLE_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | b64)"

# 3. The bundle travels in pieces of CHUNK_BYTES (SSM limits the size of one command),
#    appended to a file on the client; the last command checks it, unpacks and installs.
total=${#BUNDLE_B64}
parts=$(( (total + CHUNK_BYTES - 1) / CHUNK_BYTES ))
sha="$(printf '%s' "$BUNDLE_B64" | { command -v sha256sum >/dev/null && sha256sum || shasum -a 256; } | cut -d' ' -f1)"
log "bundle: commit $commit ($branch), uncommitted changes: $dirty, $total bytes in $parts part(s)"
for (( i = 0; i < parts; i++ )); do
  op='>>'; [[ $i -eq 0 ]] && op='>'
  printf '{"executionTimeout":["300"],"commands":["set -euo pipefail","printf %%s %s %s /root/bench-bundle.b64"]}' \
    "${BUNDLE_B64:$(( i * CHUNK_BYTES )):$CHUNK_BYTES}" "$op" > "$PARAMS"
  send "$PARAMS" "bench deploy ($SIDE) part $(( i + 1 ))/$parts" quiet
done

printf '{"executionTimeout":["900"],"commands":["set -euo pipefail","test $(sha256sum /root/bench-bundle.b64 | cut -c1-64) = %s || { echo bundle damaged in transit; exit 1; }","base64 -d < /root/bench-bundle.b64 > /root/bench-bundle.tgz","rm -f /root/bench-bundle.b64","echo %s | base64 -d > /root/bench-remote.sh","echo %s | base64 -d > /root/bench-version.json","bash /root/bench-remote.sh deploy /root/bench-bundle.tgz /root/bench-version.json %s %s"]}' \
  "$sha" "$REMOTE_B64" "$VERSION_B64" "${PACKAGES:--}" "${RUN_TESTS:-1}" > "$PARAMS"
send "$PARAMS" "bench deploy ($SIDE)"
log "done"
