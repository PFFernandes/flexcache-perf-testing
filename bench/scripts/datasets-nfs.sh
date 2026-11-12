#!/usr/bin/env bash
# Creates the t-shirt size datasets on an NFS mount, one after the other.
# Installed on the clients by stacks/05-bench as `bench-datasets-nfs`.
#
#   bench-datasets-nfs [options] SIZE... | all
#
# Sizes (profiles/datasets/<size>.json; KiB/MiB/GiB = powers of 1024):
#   small      64 KiB files,  10 GiB   (163 840 files)
#   2xsmall     1 MiB files,  50 GiB   ( 51 200 files)
#   medium      5 MiB files, 100 GiB   ( 20 480 files)
#   2xmedium   10 MiB files, 200 GiB   ( 20 480 files)
#   large      50 MiB files, 250 GiB   (  5 120 files)
#   2xlarge     1 GiB files, 300 GiB   (    300 files)
#   all = all six, 910 GiB
#
# Options:
#   --target DIR    NFS mount to write into (default /mnt/fsxn/vol_origin)
#   --side SIDE     origin (default) or cache: which side DIR is on
#   --scale F       write F x each total, same file size (e.g. 0.01 for a 1 % trial run;
#                   2xlarge needs at least 0.0034 to hold one whole 1 GiB file)
#   --jobs N        parallel writers per dataset (default: the profile's)
#   --dry-run       show the plan and the space check, write nothing
#   --background    keep running after you log out; output goes to a log file
#   --keep-going    continue with the next size if one fails (default: stop)
#   --force         skip the free-space check across all selected sizes
#   --allow-non-nfs write to a non-NFS folder (for testing the script only)
#
# Every dataset is created with `bench-dataset create`, so each one gets its own
# id (ds-<size>-<utc time>), manifest and per-file timings. With the results volume they are
# staged locally while writing and copied to /mnt/fsxn/vol_bench/datasets after the last size.
set -euo pipefail

SIZES=(small 2xsmall medium 2xmedium large 2xlarge)
SPACE_MARGIN_PCT=10

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_HOME="${BENCH_HOME:-$(cd "$HERE/../.." && pwd)}"
export BENCH_HOME
export PYTHONPATH="$BENCH_HOME${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
# Results volume (modules/11-bench-telemetry): records and logs are staged locally during the
# run and copied to the volume once, after the last size (nothing touches it while writing).
if [[ -r /etc/bench/bench.env ]]; then set -a; . /etc/bench/bench.env; set +a; fi
if [[ -n "${BENCH_STAGING:-}" ]]; then
  umask 000
  LOG_DIR="$BENCH_STAGING/logs"
else
  export BENCH_OUT="${BENCH_OUT:-$HOME/bench-results/datasets}"
  LOG_DIR="$HOME/bench-results/logs"
fi
COPIED=false
copy_results() {
  [[ -n "${BENCH_STAGING:-}" && -z "${BENCH_NO_SYNC:-}" ]] || return 0
  log "copying the results to the results volume"
  if command -v bench-results-sync >/dev/null; then
    bench-results-sync && COPIED=true
  else
    sudo -n env PYTHONPATH="$BENCH_HOME" python3 -m bench.results.sync && COPIED=true
  fi
  $COPIED || log "WARNING: the copy failed; copy them later with: bench-results-sync"
}
bench_dataset() { python3 -m bench.dataset "$@"; }

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "error: $*" >&2; exit 2; }
human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }

TARGET=/mnt/fsxn/vol_origin SIDE=origin SCALE=1 JOBS="" DRY=false BACKGROUND=false KEEP_GOING=false FORCE=false ALLOW_NON_NFS=false
ORIG_ARGS=("$@")
selected=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:?--target needs a folder}"; shift 2 ;;
    --side) SIDE="${2:?--side needs origin or cache}"; shift 2 ;;
    --scale) SCALE="${2:?--scale needs a number}"; shift 2 ;;
    --jobs) JOBS="${2:?--jobs needs a number}"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    --background) BACKGROUND=true; shift ;;
    --keep-going) KEEP_GOING=true; shift ;;
    --force) FORCE=true; shift ;;
    --allow-non-nfs) ALLOW_NON_NFS=true; shift ;;
    -h|--help) usage ;;
    all) selected+=("${SIZES[@]}"); shift ;;
    -*) echo "unknown option $1" >&2; usage 2 ;;
    *) selected+=("$1"); shift ;;
  esac
done

[[ ${#selected[@]} -gt 0 ]] || { echo "error: name at least one size, or all" >&2; usage 2; }
for s in "${selected[@]}"; do
  [[ " ${SIZES[*]} " == *" $s "* ]] || die "unknown size '$s' (sizes: ${SIZES[*]})"
done
# Drop duplicates, keep the order given.
uniq_sizes=()
for s in "${selected[@]}"; do [[ " ${uniq_sizes[*]-} " == *" $s "* ]] || uniq_sizes+=("$s"); done
selected=("${uniq_sizes[@]}")
[[ "$SIDE" == origin || "$SIDE" == cache ]] || die "--side must be origin or cache"
awk -v s="$SCALE" 'BEGIN { exit !(s > 0 && s <= 1) }' || die "--scale must be > 0 and <= 1"
[[ -z "$JOBS" || "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive whole number"

# --- the target must be an NFS mount ------------------------------------------------
[[ -d "$TARGET" ]] || die "$TARGET does not exist (is the volume mounted? check: df -h $TARGET)"
[[ -w "$TARGET" ]] || die "$TARGET is not writable by $(id -un)"
mnt() { findmnt -n -o "$1" --target "$TARGET" 2>/dev/null || echo unknown; }   # util-linux, on the clients
fstype="$(mnt FSTYPE)" options="$(mnt OPTIONS)" source="$(mnt SOURCE)"
if [[ "$fstype" != nfs* ]]; then
  $ALLOW_NON_NFS || die "$TARGET is not an NFS mount (type: $fstype). Use the /mnt/fsxn/* mounts, or --allow-non-nfs to test the script."
  log "WARNING: $TARGET is $fstype, not NFS (--allow-non-nfs)"
fi

# --- background: re-run under nohup with a log file -----------------------------------
if $BACKGROUND; then
  mkdir -p "$LOG_DIR"
  logfile="$LOG_DIR/datasets-nfs-$(id -un)-$(date -u +%Y%m%d-%H%M%S).log"
  rest=()
  for a in "${ORIG_ARGS[@]}"; do [[ "$a" == --background ]] || rest+=("$a"); done
  nohup bash "${BASH_SOURCE[0]}" "${rest[@]}" > "$logfile" 2>&1 < /dev/null &
  echo "running in the background (pid $!); follow it with:"
  echo "  tail -f $logfile"
  exit 0
fi

# --- plan: totals per size, then one space check for all of them -----------------------
profile_sizes() { # <size> -> "<total bytes> <file size bytes>" from profiles/datasets/<size>.json
  python3 -c 'import sys
from bench.dataset import spec
s = spec.normalize(spec.load_file(spec.find_spec(sys.argv[1])))
print(s["total"], s["buckets"][0]["hi"])' "$1"
}

declare -a totals=()
need=0
for s in "${selected[@]}"; do
  read -r full file_size < <(profile_sizes "$s")
  t="$(awk -v t="$full" -v f="$SCALE" 'BEGIN { printf "%.0f", t * f }')"
  if (( t < file_size )); then
    log "WARNING: at --scale $SCALE, $s ($(human "$t")) holds less than one $(human "$file_size") file: it becomes one shorter file"
  fi
  totals+=("$t")
  need=$((need + t))
done
free=$(( $(df -P -k "$TARGET" | awk 'NR == 2 { print $4 }') * 1024 ))
need_margin=$(( need + need * SPACE_MARGIN_PCT / 100 ))

log "target  $TARGET ($fstype from $source)"
log "options $options"
if [[ -n "${BENCH_STAGING:-}" ]]; then
  records="$BENCH_STAGING/datasets while writing, then $BENCH_RESULTS_DIR/datasets"
else
  records="$BENCH_OUT"
fi
log "side    $SIDE, scale $SCALE, records in $records"
for i in "${!selected[@]}"; do
  log "  $(printf '%-9s' "${selected[$i]}") $(human "${totals[$i]}")"
done
log "total   $(human "$need") (+${SPACE_MARGIN_PCT}% margin = $(human "$need_margin")); free $(human "$free")"
if (( need_margin > free )); then
  if $FORCE; then
    log "WARNING: not enough free space for all selected sizes; continuing because of --force"
  else
    fits=() used=0
    for i in "${!selected[@]}"; do
      t=${totals[$i]}
      if (( used + t + (used + t) * SPACE_MARGIN_PCT / 100 <= free )); then fits+=("${selected[$i]}"); used=$((used + t)); fi
    done
    die "not enough free space for all of them together. In this order, these fit: ${fits[*]:-none}. Pick fewer sizes, delete old datasets (bench-dataset list / delete), use --scale, or grow the volume."
  fi
fi

# --- create, one size at a time ---------------------------------------------------------
results=()
failed=0
for i in "${!selected[@]}"; do
  s="${selected[$i]}"
  id="ds-${s}-$(date -u +%Y%m%d-%H%M%S)"
  sizing=()
  [[ "$SCALE" == 1 ]] || sizing=(--total "${totals[$i]}")
  [[ -z "$JOBS" ]] || sizing+=(--jobs "$JOBS")
  args=(create --spec "$s" --target "$TARGET" --side "$SIDE" --id "$id" ${sizing[@]+"${sizing[@]}"})
  if $DRY; then
    log "=== $s: would run: bench-dataset ${args[*]}"
    bench_dataset plan --spec "$s" ${sizing[@]+"${sizing[@]}"} | sed 's/^/    /'
    continue
  fi
  log "=== $s -> $id"
  start=$(date +%s)
  if bench_dataset "${args[@]}"; then
    status=ok
  else
    status=FAILED; failed=$((failed + 1))
  fi
  results+=("$(printf '%-9s %-32s %-6s %6ss' "$s" "$id" "$status" "$(( $(date +%s) - start ))")")
  if [[ "$status" != ok ]] && ! $KEEP_GOING; then
    log "stopping after the failure of $s (use --keep-going to continue with the next size)"
    break
  fi
done

$DRY && { log "dry run: nothing written"; exit 0; }
copy_results
log "summary"
for r in "${results[@]}"; do echo "  $r"; done
if [[ -z "${BENCH_STAGING:-}" ]]; then where="$BENCH_OUT"
elif $COPIED; then where="$BENCH_RESULTS_DIR/datasets (results volume)"
else where="$BENCH_STAGING/datasets (staged, not copied yet)"; fi
log "records: $where   (list them with: bench-dataset list)"
[[ $failed -eq 0 ]] || exit 1
