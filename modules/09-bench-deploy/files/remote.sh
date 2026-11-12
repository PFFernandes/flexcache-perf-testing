#!/usr/bin/env bash
# Runs ON THE EC2 CLIENT as root (sent by deploy.sh over SSM Run Command).
#
#   remote.sh deploy <bundle.tgz> <version.json> <packages,comma,separated or -> <run_tests 0|1>
#   remote.sh remove
#
# deploy: unpacks the bench into $BENCH_HOME (default /opt/bench), swapping the old copy
#         out only once the new one is complete; installs the bench-dataset,
#         bench-datasets-nfs and bench-results-sync commands;
#         installs extra packages; prints checks; runs the bench tests.
# remove: deletes $BENCH_HOME and the wrapper. Dataset files on the volumes and the
#         records in each user's ~/bench-results are not touched.
set -euo pipefail

BENCH_HOME="${BENCH_HOME:-/opt/bench}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
log() { echo "[bench-deploy] $*"; }

ACTION="${1:?action}"

if [[ "$ACTION" == "remove" ]]; then
  rm -rf "$BENCH_HOME" "$BENCH_HOME.new" "$BENCH_HOME.old" "$BIN_DIR/bench-dataset" "$BIN_DIR/bench-datasets-nfs" "$BIN_DIR/bench-results-sync"
  log "removed $BENCH_HOME and the bench commands (datasets and ~/bench-results are kept)"
  exit 0
fi

[[ "$ACTION" == "deploy" ]] || { log "unknown action $ACTION"; exit 1; }
BUNDLE="${2:?bundle}"; VERSION_FILE="${3:?version}"; PACKAGES="${4:?packages, - for none}"; RUN_TESTS="${5:?run_tests 0|1}"
[[ "$PACKAGES" == "-" ]] && PACKAGES=""

# 1. Unpack next to the old copy, then swap, so a failed unpack never leaves half a bench.
rm -rf "$BENCH_HOME.new" "$BENCH_HOME.old"
mkdir -p "$BENCH_HOME.new"
tar_opts=()
tar --version 2>/dev/null | grep -q 'GNU tar' && tar_opts+=(--warning=no-unknown-keyword)
tar -xzf "$BUNDLE" -C "$BENCH_HOME.new" --no-same-owner ${tar_opts[@]+"${tar_opts[@]}"}
cp "$VERSION_FILE" "$BENCH_HOME.new/VERSION.json"
chmod -R u=rwX,go=rX "$BENCH_HOME.new"
[[ -d "$BENCH_HOME" ]] && mv "$BENCH_HOME" "$BENCH_HOME.old"
mv "$BENCH_HOME.new" "$BENCH_HOME"
rm -rf "$BENCH_HOME.old" "$BUNDLE" "$VERSION_FILE"
log "bench unpacked in $BENCH_HOME"

# 2. Commands, usable from any folder by any user (ssm-user, ec2-user).
#    With the results volume (/etc/bench/bench.env, from modules/11-bench-telemetry), a command
#    writes its records to the local staging folder and they are copied to the results volume
#    only AFTER the command has finished: nothing is written to the volume during a test.
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/bench-dataset" <<WRAPPER
#!/bin/sh
# Installed by modules/09-bench-deploy.
export PYTHONPATH="$BENCH_HOME\${PYTHONPATH:+:\$PYTHONPATH}"
export BENCH_HOME="$BENCH_HOME"
export PYTHONDONTWRITEBYTECODE=1
if [ -r /etc/bench/bench.env ]; then set -a; . /etc/bench/bench.env; set +a; fi
if [ -n "\${BENCH_STAGING:-}" ]; then
  umask 000          # staging and results are shared by every user
else
  export BENCH_OUT="\${BENCH_OUT:-\$HOME/bench-results/datasets}"
fi
python3 -m bench.dataset "\$@"
rc=\$?
# plan, list and --help write nothing; BENCH_NO_SYNC=1 leaves the copy to the caller.
case " \$* " in *" plan "*|*" list "*|*" -h "*|*" --help "*) exit \$rc ;; esac
if [ -n "\${BENCH_STAGING:-}" ] && [ -z "\${BENCH_NO_SYNC:-}" ]; then
  "$BIN_DIR/bench-results-sync" --quiet || echo "bench-dataset: results are still in \$BENCH_STAGING; copy them later with: bench-results-sync" >&2
fi
exit \$rc
WRAPPER
chmod 755 "$BIN_DIR/bench-dataset"

cat > "$BIN_DIR/bench-results-sync" <<WRAPPER
#!/bin/sh
# Installed by modules/09-bench-deploy: copy results from the staging folder to the results
# volume. Runs as root (the collector's files belong to its service user).
if [ "\$(id -u)" -ne 0 ]; then exec sudo -n "\$0" "\$@"; fi
if [ -r /etc/bench/bench.env ]; then set -a; . /etc/bench/bench.env; set +a; fi
export PYTHONPATH="$BENCH_HOME" PYTHONDONTWRITEBYTECODE=1
exec python3 -m bench.results.sync "\$@"
WRAPPER
chmod 755 "$BIN_DIR/bench-results-sync"

cat > "$BIN_DIR/bench-datasets-nfs" <<WRAPPER
#!/bin/sh
# Installed by modules/09-bench-deploy: creates the t-shirt size datasets on an NFS mount.
export BENCH_HOME="$BENCH_HOME"
exec bash "$BENCH_HOME/bench/scripts/datasets-nfs.sh" "\$@"
WRAPPER
chmod 755 "$BIN_DIR/bench-datasets-nfs"
log "installed $BIN_DIR/bench-dataset, bench-datasets-nfs and bench-results-sync"

# 3. Extra packages (from the Amazon Linux repos, reached through the S3 gateway endpoint).
if [[ -n "$PACKAGES" ]]; then
  # shellcheck disable=SC2086
  if dnf install -y -q ${PACKAGES//,/ }; then
    log "packages installed: ${PACKAGES//,/ }"
  else
    log "WARNING: could not install: ${PACKAGES//,/ }"
  fi
fi

# 4. Checks.
log "version: $(tr -d '\n' < "$BENCH_HOME/VERSION.json")"
log "python:  $(python3 --version 2>&1)"
if python3 -c 'import yaml' 2>/dev/null; then
  log "PyYAML:  yes (.yaml specs work)"
else
  log "PyYAML:  no (use .json specs or flags, or add python3-pyyaml to install_packages)"
fi
found=0
for dir in /mnt/fsxn/*; do
  [[ -d "$dir" ]] || continue
  found=1
  if mountpoint -q "$dir"; then
    log "mount:   $dir mounted, $(df -h --output=avail "$dir" | tail -1 | tr -d ' ') free"
  else
    log "mount:   $dir NOT mounted yet"
  fi
done
[[ $found -eq 1 ]] || log "mount:   no /mnt/fsxn/* folders on this machine"

# 5. Tests (offline, in a temporary folder; they don't touch the volumes).
if [[ "$RUN_TESTS" == "1" ]]; then
  if out="$(cd "$BENCH_HOME" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s bench/tests -t . 2>&1)"; then
    log "tests:   $(echo "$out" | grep -E '^Ran ' || true), OK"
  else
    echo "$out"
    log "tests:   FAILED"
    exit 1
  fi
fi
log "OK"
