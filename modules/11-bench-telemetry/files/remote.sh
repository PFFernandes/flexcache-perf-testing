#!/usr/bin/env bash
# Runs ON THE EC2 CLIENT as root (sent by install.sh over SSM Run Command).
#
#   remote.sh install <settings.env> <collector.yaml> <probe.json> <lab.json>
#   remote.sh remove
#
# install: mounts the results volume (FSx for ONTAP, NFS) at $RESULTS_MOUNT, creates the local
#          staging folder $STAGING where results are written DURING a test, installs the
#          OpenTelemetry Collector from the package bucket (checked against its SHA-256),
#          validates and applies its config (it writes to $STAGING, never to the volume),
#          starts it and bench-probe, writes /etc/bench/bench.env for the bench commands and
#          labs/<lab>/lab.json on the volume, and checks that telemetry is being staged.
# remove:  stops both services, copies everything staged to the results volume (fails if it
#          can't, so the results aren't lost), then removes the package and unmounts the volume
#          (its fstab entry goes too). Everything on the volume stays.
set -euo pipefail

log() { echo "[bench-telemetry] $*"; }
ACTION="${1:?action}"
CONF=/etc/otelcol-contrib/config.yaml
PROBE_UNIT=/etc/systemd/system/bench-probe.service
DROPIN_DIR=/etc/systemd/system/otelcol-contrib.service.d
FSTAB_TAG="# bench results volume (modules/11-bench-telemetry)"

if [[ "$ACTION" == "remove" ]]; then
  systemctl disable --now bench-probe otelcol-contrib 2>/dev/null || true   # flushes its last batch
  # Final copy of everything staged, before the volume is unmounted (and later deleted + backed up).
  if [[ -r /etc/bench/bench.env ]]; then
    set -a; . /etc/bench/bench.env; set +a
    if [[ -n "${BENCH_STAGING:-}" && -d "$BENCH_STAGING" ]]; then
      if ! PYTHONPATH=/opt/bench PYTHONDONTWRITEBYTECODE=1 python3 -m bench.results.sync; then
        log "the final copy to the results volume FAILED: the staged results are still in $BENCH_STAGING."
        log "Fix the mount ($BENCH_RESULTS_DIR) and destroy again; nothing was removed."
        exit 1
      fi
    fi
  fi
  rm -rf "$PROBE_UNIT" "$DROPIN_DIR" /etc/bench/probe.json /etc/bench/bench.env
  systemctl daemon-reload
  if rpm -q otelcol-contrib >/dev/null 2>&1; then rpm -e otelcol-contrib; fi
  mnt="$(grep -A1 -F "$FSTAB_TAG" /etc/fstab | tail -1 | awk '{print $2}' || true)"
  if [[ -n "$mnt" ]]; then
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    sed -i "\\|$FSTAB_TAG|,+1d" /etc/fstab
  fi
  log "removed the collector, bench-probe and the results mount (the data on the volume stays)"
  exit 0
fi
[[ "$ACTION" == "install" ]] || { log "unknown action $ACTION"; exit 1; }

# shellcheck disable=SC1090
source "${2:?settings}"   # VERSION SHA_AMD64 SHA_ARM64 BUCKET BUCKET_REGION LAB SIDE INSTANCE_ID
                          # RESULTS_SERVER RESULTS_EXPORT RESULTS_MOUNT RESULTS_OPTIONS STAGING FLUSH_S
                          # CLOUDWATCH_NAMESPACE (- = off) CLOUDWATCH_REGION
COLLECTOR_YAML="${3:?collector.yaml}"; PROBE_JSON="${4:?probe.json}"; LAB_JSON="${5:?lab.json}"
TELEMETRY_DIR="$STAGING/telemetry/$LAB/$SIDE/$INSTANCE_ID"   # local; copied to the volume after tests

# 1. Results volume: fstab entry (also picked up by the client's fsxn-mount timer), then mount.
mkdir -p "$RESULTS_MOUNT"
entry="$RESULTS_SERVER:$RESULTS_EXPORT $RESULTS_MOUNT nfs $RESULTS_OPTIONS,_netdev,nofail 0 0"
if grep -qF "$FSTAB_TAG" /etc/fstab; then sed -i "\\|$FSTAB_TAG|,+1d" /etc/fstab; fi
printf '%s\n%s\n' "$FSTAB_TAG" "$entry" >> /etc/fstab
systemctl daemon-reload
for i in $(seq 1 12); do
  mountpoint -q "$RESULTS_MOUNT" && break
  mount "$RESULTS_MOUNT" 2>/dev/null || true
  mountpoint -q "$RESULTS_MOUNT" && break
  [[ $i -eq 12 ]] && { log "could not mount $RESULTS_SERVER:$RESULTS_EXPORT at $RESULTS_MOUNT (is the volume created and the NFS IP reachable?)"; exit 1; }
  sleep 5
done
# Shared by every user and both clients: anyone may add results, the sticky bit stops
# people deleting each other's top-level folders.
chmod 1777 "$RESULTS_MOUNT"
for d in datasets labs logs telemetry; do mkdir -p "$RESULTS_MOUNT/$d" && chmod 1777 "$RESULTS_MOUNT/$d"; done
mkdir -p "$RESULTS_MOUNT/labs/$LAB"
install -m 0644 "$LAB_JSON" "$RESULTS_MOUNT/labs/$LAB/lab.json"
log "results volume: $RESULTS_SERVER:$RESULTS_EXPORT on $RESULTS_MOUNT, $(df -h --output=avail "$RESULTS_MOUNT" | tail -1 | tr -d ' ') free"

# 2. Package from the package bucket (no internet here), only when the version changes.
case "$(uname -m)" in
  x86_64) arch=amd64; want="$SHA_AMD64" ;;
  aarch64) arch=arm64; want="$SHA_ARM64" ;;
  *) log "unsupported architecture $(uname -m)"; exit 1 ;;
esac
installed=""
if rpm -q otelcol-contrib >/dev/null 2>&1; then installed="$(rpm -q --qf '%{VERSION}' otelcol-contrib)"; fi
if [[ "$installed" != "$VERSION" ]]; then
  [[ -n "$want" ]] || { log "no $arch package staged (collector_architectures in stack 05)"; exit 1; }
  rpm_file="/root/otelcol-contrib_${VERSION}_linux_${arch}.rpm"
  aws s3 cp --region "$BUCKET_REGION" --only-show-errors \
    "s3://$BUCKET/vendor/otelcol-contrib/$VERSION/$(basename "$rpm_file")" "$rpm_file"
  got="$(sha256sum "$rpm_file" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || { rm -f "$rpm_file"; log "SHA-256 mismatch: expected $want, got $got"; exit 1; }
  rpm -U --replacepkgs "$rpm_file"
  rm -f "$rpm_file"
  log "installed otelcol-contrib $VERSION ($arch)${installed:+, was $installed}"
else
  log "otelcol-contrib $VERSION already installed"
fi
command -v ethtool >/dev/null || dnf install -y -q ethtool >/dev/null 2>&1 || log "WARNING: no ethtool: no ENA allowance metrics"

# 3. Local staging: during a test everything is written here, never to the results volume.
#    Shared by every user (sticky bit); the collector's folder belongs to its service user.
mkdir -p "$STAGING" "$STAGING/datasets" "$STAGING/logs" "$TELEMETRY_DIR"
chmod 1777 "$STAGING" "$STAGING/datasets" "$STAGING/logs"
chmod 0755 "$STAGING/telemetry"
chown otelcol-contrib:otelcol-contrib "$TELEMETRY_DIR"
rm -rf "$DROPIN_DIR"   # older versions waited for the volume; the collector now writes locally

# 4. Collector config: validate before it replaces the running one.
install -m 0644 "$COLLECTOR_YAML" "$CONF.new"
if ! out="$(/usr/bin/otelcol-contrib validate --config="$CONF.new" 2>&1)"; then
  echo "$out"
  rm -f "$CONF.new"
  log "the collector config is invalid; the running collector was left as it was"
  exit 1
fi
mv "$CONF.new" "$CONF"

# 5. Settings for the bench commands, and the probe.
mkdir -p /etc/bench
cat > /etc/bench/bench.env <<ENV
# Written by modules/11-bench-telemetry. Read by bench-dataset and bench-datasets-nfs.
BENCH_LAB=$LAB
BENCH_SIDE=$SIDE
BENCH_RESULTS_DIR=$RESULTS_MOUNT
BENCH_STAGING=$STAGING
ENV
if [[ "${CLOUDWATCH_NAMESPACE:--}" != "-" ]]; then
  # bench-results-sync pushes each test's metrics to CloudWatch after the test.
  printf 'BENCH_CLOUDWATCH_REGION=%s\nBENCH_CLOUDWATCH_NAMESPACE=%s\n' "$CLOUDWATCH_REGION" "$CLOUDWATCH_NAMESPACE" >> /etc/bench/bench.env
fi
chmod 0644 /etc/bench/bench.env
install -m 0644 "$PROBE_JSON" /etc/bench/probe.json
cat > "$PROBE_UNIT" <<'UNIT'
[Unit]
Description=bench-probe: NFS, ENA and ping metrics for the OpenTelemetry Collector
After=otelcol-contrib.service network-online.target
Wants=otelcol-contrib.service

[Service]
Environment=PYTHONPATH=/opt/bench PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 -m bench.telemetry.probe --config /etc/bench/probe.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable otelcol-contrib bench-probe >/dev/null 2>&1
systemctl restart otelcol-contrib bench-probe
rm -f "$2" "$COLLECTOR_YAML" "$PROBE_JSON" "$LAB_JSON"

# 6. Checks: both services up, and telemetry being written to the volume.
for i in $(seq 1 15); do
  curl -sf http://127.0.0.1:13133/ >/dev/null && break
  [[ $i -eq 15 ]] && { journalctl -u otelcol-contrib -n 30 --no-pager; log "the collector is not healthy"; exit 1; }
  sleep 2
done
log "collector: healthy"
sleep 3
systemctl is-active --quiet bench-probe || { journalctl -u bench-probe -n 30 --no-pager; log "bench-probe is not running"; exit 1; }
log "probe:     running"

file="$TELEMETRY_DIR/metrics.json"
start_size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
wait_s=$(( FLUSH_S + 30 ))
log "waiting up to ${wait_s} s for telemetry in $file (local staging) ..."
for i in $(seq 1 $(( wait_s / 5 ))); do
  size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  if (( size > start_size )); then
    log "staging:   writing, $file is $size bytes (copied to $RESULTS_MOUNT after each test)"
    log "OK"
    exit 0
  fi
  sleep 5
done
journalctl -u otelcol-contrib -n 30 --no-pager
log "no telemetry staged in $file after ${wait_s} s (see the collector log above)"
exit 1
