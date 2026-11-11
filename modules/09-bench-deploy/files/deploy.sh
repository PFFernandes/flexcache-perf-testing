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
MAX_PARAMS_BYTES=60000   # stay below the SSM Run Command parameter limit
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

# 2. Build the command. Only base64 text and fixed words go into the JSON: no escaping needed.
REMOTE_B64="$(b64 < "$REMOTE_SH")"
PARAMS="$(mktemp)"
trap 'rm -f "$PARAMS"' EXIT

if [[ "$ACTION" == "deploy" ]]; then
  : "${SOURCE_ROOT:?}" "${SOURCE_DIRS:?}" "${BUNDLE_HASH:?}"
  tar_opts=(--exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store')
  if tar --version 2>/dev/null | grep -q bsdtar; then
    tar_opts+=(--no-mac-metadata --no-xattrs)   # no ._ files or macOS attributes on Linux
  fi
  # shellcheck disable=SC2086
  BUNDLE_B64="$(COPYFILE_DISABLE=1 tar -C "$SOURCE_ROOT" "${tar_opts[@]}" -czf - $SOURCE_DIRS | b64)"

  commit="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  branch="$(git -C "$SOURCE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  dirty=false
  [[ -n "$(git -C "$SOURCE_ROOT" status --porcelain -- $SOURCE_DIRS 2>/dev/null)" ]] && dirty=true
  VERSION_B64="$(printf '{"commit":"%s","branch":"%s","uncommitted_changes":%s,"bundle_sha256":"%s","deployed":"%s"}\n' \
    "$commit" "$branch" "$dirty" "$BUNDLE_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | b64)"

  printf '{"executionTimeout":["900"],"commands":["set -euo pipefail","echo %s | base64 -d > /root/bench-remote.sh","echo %s | base64 -d > /root/bench-bundle.tgz","echo %s | base64 -d > /root/bench-version.json","bash /root/bench-remote.sh deploy /root/bench-bundle.tgz /root/bench-version.json %s %s"]}' \
    "$REMOTE_B64" "$BUNDLE_B64" "$VERSION_B64" "${PACKAGES:--}" "${RUN_TESTS:-1}" > "$PARAMS"
  log "bundle: commit $commit ($branch), uncommitted changes: $dirty, $(wc -c < "$PARAMS" | tr -d ' ') bytes"
else
  printf '{"executionTimeout":["300"],"commands":["set -euo pipefail","echo %s | base64 -d > /root/bench-remote.sh","bash /root/bench-remote.sh remove"]}' \
    "$REMOTE_B64" > "$PARAMS"
fi

size="$(wc -c < "$PARAMS" | tr -d ' ')"
if (( size > MAX_PARAMS_BYTES )); then
  log "the bundle is too big for one SSM command ($size bytes, limit $MAX_PARAMS_BYTES)."
  log "Deliver it through S3 instead (planned with the Tooling module), or exclude large files."
  exit 1
fi

# 3. Send and wait.
CMD_ID="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "bench $ACTION ($SIDE)" \
  --parameters "file://$PARAMS" --timeout-seconds 600 \
  --query Command.CommandId --output text)"
log "SSM command $CMD_ID sent to $INSTANCE_ID ($ACTION); waiting..."

status=""
while true; do
  status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Pending|InProgress|Delayed) sleep 5 ;;
    *) break ;;
  esac
done

aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text
err="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardErrorContent --output text)"
[[ -n "$err" && "$err" != "None" ]] && echo "$err" >&2

if [[ "$status" != "Success" ]]; then
  log "FAILED ($status). Full log: aws ssm get-command-invocation --region $REGION --command-id $CMD_ID --instance-id $INSTANCE_ID"
  exit 1
fi
log "done"
