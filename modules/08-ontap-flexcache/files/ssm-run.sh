#!/usr/bin/env bash
# Runs on YOUR MAC (Terraform local-exec in modules/08-ontap-flexcache).
# Sends the FlexCache script to the origin EC2 client with SSM Run Command, waits
# for it to finish and prints its output. Exit code 0 only if the script succeeded.
#   Linux client (protocol nfs):   flexcache.py  with AWS-RunShellScript
#   Windows client (protocol smb): flexcache.ps1 with AWS-RunPowerShellScript
#
# Environment (set by Terraform):
#   ACTION        create | delete
#   REGION        region of the origin client
#   INSTANCE_ID   origin client instance ID
#   CLIENT_OS     linux | windows (default linux)
#   SCRIPT_GZ64   the script, gzip + base64
#   CONFIG_B64    JSON config, base64 (IPs, names, secret ARN - no password)
set -euo pipefail

: "${ACTION:?}" "${REGION:?}" "${INSTANCE_ID:?}" "${SCRIPT_GZ64:?}" "${CONFIG_B64:?}"
CLIENT_OS="${CLIENT_OS:-linux}"
log() { echo "[ssm-run] $*"; }

# 1. The client's SSM agent must be online (it needs the SSM endpoints of 03-ec2).
for i in $(seq 1 60); do
  ping="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$ping" == "Online" ]] && break
  [[ $i -eq 60 ]] && { log "origin client $INSTANCE_ID is not online in SSM (status: ${ping:-none}). Is enable_ssm = true in stacks/03-ec2?"; exit 1; }
  log "waiting for $INSTANCE_ID to be online in SSM (status: ${ping:-none})..."
  sleep 10
done

# 2. Send the script. Only base64 characters are filled into the JSON, and the fixed
#    commands contain no double quotes or backslashes, so no escaping is needed.
PARAMS="$(mktemp)"
trap 'rm -f "$PARAMS"' EXIT
if [[ "$CLIENT_OS" == "windows" ]]; then
  DOCUMENT=AWS-RunPowerShellScript
  printf '{"executionTimeout":["3600"],"commands":["$ErrorActionPreference = %s","$gz = New-Object IO.Compression.GzipStream((New-Object IO.MemoryStream(,[Convert]::FromBase64String(%s))), [IO.Compression.CompressionMode]::Decompress)","$path = Join-Path $env:SystemRoot %s","Set-Content -Path $path -Value (New-Object IO.StreamReader($gz)).ReadToEnd() -Encoding UTF8","& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path %s %s","exit $LASTEXITCODE"]}' \
    "'Stop'" "'$SCRIPT_GZ64'" "'Temp/flexcache.ps1'" "$ACTION" "$CONFIG_B64" > "$PARAMS"
else
  DOCUMENT=AWS-RunShellScript
  printf '{"executionTimeout":["3600"],"commands":["set -euo pipefail","echo %s | base64 -d | gunzip > /root/flexcache.py","python3 /root/flexcache.py %s %s"]}' \
    "$SCRIPT_GZ64" "$ACTION" "$CONFIG_B64" > "$PARAMS"
fi

CMD_ID="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name "$DOCUMENT" --comment "flexcache $ACTION" \
  --parameters "file://$PARAMS" --timeout-seconds 600 \
  --query Command.CommandId --output text)"
log "SSM command $CMD_ID sent to $INSTANCE_ID ($ACTION); waiting..."

# 3. Wait for it to finish.
status=""
while true; do
  status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$status" in
    Pending|InProgress|Delayed) sleep 10 ;;
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
log "OK"
