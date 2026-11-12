"""bench-results-sync: copy results from the client's staging folder to the results volume.

During a test nothing is written to the results volume (vol_bench, FSx for ONTAP): extra NFS
writes would load the file systems being measured. Everything goes to a local staging folder
first, and this copies it over once the test has finished:

    <staging>/datasets/<id>/    dataset records   -> <results>/datasets/<id>/   then removed locally
    <staging>/logs/*            command logs      -> <results>/logs/            kept locally
    <staging>/telemetry/...     Collector output  -> <results>/telemetry/...
        rotated files (metrics-<time>.json) are removed locally once copied;
        the file being written (metrics.json) is copied as it is and kept.

A dataset folder that a running command holds (flock on <id>/.lock) is skipped: it is copied
by that command's own sync when it ends.

With $BENCH_CLOUDWATCH_REGION set (stack 05, cloudwatch = true), the new minutes of telemetry and
the new dataset timings are first pushed to Amazon CloudWatch (bench/results/cloudwatch.py), so the
CloudWatch dashboard shows the test next to the FSx and EC2 metrics. A failed push is reported and
retried next time; it never stops the copy. Runs as root (the Collector's files belong to its
service user):  sudo bench-results-sync
"""
from __future__ import annotations

import argparse
import fcntl
import os
import shutil
import sys
import time

ACTIVE_TELEMETRY = "metrics.json"
LOCK_NAME = ".lock"


def _copy(src: str, dst: str) -> None:
    """Copy a file via a temporary name, so a half-copied file is never seen under its name."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".sync-tmp"
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def _same(src: str, dst: str) -> bool:
    try:
        a, b = os.stat(src), os.stat(dst)
    except FileNotFoundError:
        return False
    return a.st_size == b.st_size and int(a.st_mtime) == int(b.st_mtime)


def _locked(folder: str) -> bool:
    """True if a running bench-dataset command holds this dataset folder."""
    path = os.path.join(folder, LOCK_NAME)
    if not os.path.exists(path):
        return False
    with open(path, "a") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        fcntl.flock(fh, fcntl.LOCK_UN)
    return False


def sync(staging: str, results: str, log=print) -> dict:
    """Copy staging -> results. Returns counts per kind."""
    counts = {"datasets": 0, "datasets_busy": 0, "logs": 0, "telemetry": 0, "telemetry_removed": 0}

    # Dataset records: the results volume is the shared copy, so a finished dataset folder
    # moves there (a later command reads it back from there).
    ds_dir = os.path.join(staging, "datasets")
    if os.path.isdir(ds_dir):
        for name in sorted(os.listdir(ds_dir)):
            src = os.path.join(ds_dir, name)
            if not os.path.isdir(src):
                continue
            if _locked(src):
                counts["datasets_busy"] += 1
                log(f"skipped datasets/{name}: a command is still using it")
                continue
            for root, _dirs, files in os.walk(src):
                for f in files:
                    if f == LOCK_NAME:
                        continue
                    s = os.path.join(root, f)
                    d = os.path.join(results, "datasets", name, os.path.relpath(s, src))
                    if not _same(s, d):
                        _copy(s, d)
            shutil.rmtree(src)
            counts["datasets"] += 1

    # Logs: copied, kept locally (a background command may still be writing its log).
    logs = os.path.join(staging, "logs")
    if os.path.isdir(logs):
        for f in sorted(os.listdir(logs)):
            s = os.path.join(logs, f)
            if os.path.isfile(s) and not _same(s, os.path.join(results, "logs", f)):
                _copy(s, os.path.join(results, "logs", f))
                counts["logs"] += 1

    # Telemetry: rotated files are complete; copy and remove them. The active file is a snapshot.
    tel = os.path.join(staging, "telemetry")
    if os.path.isdir(tel):
        for root, _dirs, files in os.walk(tel):
            for f in sorted(files):
                s = os.path.join(root, f)
                d = os.path.join(results, "telemetry", os.path.relpath(s, tel))
                if not _same(s, d):
                    _copy(s, d)
                    counts["telemetry"] += 1
                if f != ACTIVE_TELEMETRY and f.startswith("metrics") and _same(s, d):
                    os.remove(s)
                    counts["telemetry_removed"] += 1
    return counts


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="bench-results-sync", description=__doc__.splitlines()[0])
    p.add_argument("--staging", default=os.environ.get("BENCH_STAGING", "/var/lib/bench/staging"))
    p.add_argument("--results", default=os.environ.get("BENCH_RESULTS_DIR", ""))
    p.add_argument("--quiet", action="store_true", help="print only a one-line summary")
    args = p.parse_args(argv)

    if not args.results:
        print("bench-results-sync: no results volume configured ($BENCH_RESULTS_DIR); nothing copied")
        return 0
    if not os.path.ismount(args.results):
        print(f"bench-results-sync: {args.results} is not mounted; results stay in {args.staging}", file=sys.stderr)
        return 1
    start = time.time()
    if os.environ.get("BENCH_CLOUDWATCH_REGION"):
        from . import cloudwatch
        try:
            cw = cloudwatch.push(args.staging, lab=os.environ.get("BENCH_LAB", "unknown-lab"),
                                 side=os.environ.get("BENCH_SIDE", "unknown"),
                                 region=os.environ["BENCH_CLOUDWATCH_REGION"],
                                 namespace=os.environ.get("BENCH_CLOUDWATCH_NAMESPACE", cloudwatch.NAMESPACE))
            print(f"bench-results-sync: sent {cw['datums']} data point(s) to CloudWatch "
                  f"({cw['series']} telemetry series, {cw['datasets']} dataset generation(s))")
        except Exception as exc:    # never block the copy to the results volume
            print(f"bench-results-sync: WARNING: CloudWatch push failed, retried next time: {exc}", file=sys.stderr)
    counts = sync(args.staging, args.results, log=(lambda m: None) if args.quiet else print)
    print(f"bench-results-sync: copied {counts['datasets']} dataset(s), {counts['logs']} log(s), "
          f"{counts['telemetry']} telemetry file(s) to {args.results} in {time.time() - start:.1f} s"
          + (f"; {counts['datasets_busy']} dataset(s) still in use, copied when they finish"
             if counts["datasets_busy"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
