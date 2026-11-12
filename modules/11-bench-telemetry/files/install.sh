#!/usr/bin/env bash
# Runs on the OPERATOR MACHINE (Terraform local-exec in modules/11-bench-telemetry).
# Sends files/remote.sh and the rendered settings to one EC2 client with SSM Run Command,
# waits and prints the client's output. Exit code 0 only if the client reports success.
#
# Environment (set by Terraform):
#   ACTION         install | remove
#   REGION         region of the client
#   INSTANCE_ID    client instance ID
#   SIDE           origin | cache (for the log)
#   REMOTE_SH      path of files/remote.sh
#   SETTINGS_B64   settings.env, base64 (install)
#   COLLECTOR_B64  collector config, base64 (install)
#   PROBE_B64      probe config, base64 (install)
#   LAB_B64        lab.json for the results volume, base64 (install)
set -euo pipefail

: "${ACTION:?}" "${REGION:?}" "${INSTANCE_ID:?}" "${REMOTE_SH:?}"
SIDE="${SIDE:-client}"
log() { echo "[bench-telemetry $SIDE] $*"; }
b64() { base64 | tr -d '\n'; }

for i in $(seq 1 30); do
  ping="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$ping" == "Online" ]] && break
  if [[ $i -eq 30 ]]; then
    if [[ "$ACTION" == "remove" ]]; then log "client $INSTANCE_ID not online in SSM; nothing to remove"; exit 0; fi
    log "client $INSTANCE_ID is not online in SSM (status: ${ping:-none})"; exit 1
  fi
  log "waiting for $INSTANCE_ID to be online in SSM (status: ${ping:-none})..."
  sleep 10
done

REMOTE_B64="$(b64 < "$REMOTE_SH")"
PARAMS="$(mktemp)"
trap 'rm -f "$PARAMS"' EXIT
if [[ "$ACTION" == "install" ]]; then
  : "${SETTINGS_B64:?}" "${COLLECTOR_B64:?}" "${PROBE_B64:?}" "${LAB_B64:?}"
  printf '{"executionTimeout":["900"],"commands":["set -euo pipefail","echo %s | base64 -d > /root/bench-telemetry.sh","echo %s | base64 -d > /root/bench-telemetry.env","echo %s | base64 -d > /root/bench-collector.yaml","echo %s | base64 -d > /root/bench-probe.json","echo %s | base64 -d > /root/bench-lab.json","bash /root/bench-telemetry.sh install /root/bench-telemetry.env /root/bench-collector.yaml /root/bench-probe.json /root/bench-lab.json"]}' \
    "$REMOTE_B64" "$SETTINGS_B64" "$COLLECTOR_B64" "$PROBE_B64" "$LAB_B64" > "$PARAMS"
else
  printf '{"executionTimeout":["300"],"commands":["set -euo pipefail","echo %s | base64 -d > /root/bench-telemetry.sh","bash /root/bench-telemetry.sh remove"]}' \
    "$REMOTE_B64" > "$PARAMS"
fi

CMD_ID="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "bench telemetry $ACTION ($SIDE)" \
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
