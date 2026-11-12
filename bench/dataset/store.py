"""What a dataset leaves behind, next to the files themselves.

    <out>/<dataset-id>/
        dataset.json             spec, where it was written, one record per generation
        manifest-g<N>.csv.gz     every file after generation N: idx, path, size, sha256, state
        ops-g<N>.csv.gz          one row per file operation of generation N, with timings
        ops-verify-<time>.csv.gz same, for a verify pass

Generation 0 is the creation; each modify adds one.
"""
from __future__ import annotations

import csv
import fcntl
import gzip
import json
import os
import sys
import time

MANIFEST_FIELDS = ["idx", "path", "size", "sha256", "state"]
OPS_FIELDS = ["ts", "idx", "action", "open_us", "first_us", "io_us", "fsync_us", "close_us", "bytes", "error"]
TIMED = ("open_us", "first_us", "io_us", "fsync_us", "close_us")


class Store:
    def __init__(self, out: str, dataset_id: str):
        self.dir = os.path.join(out, dataset_id)
        self.id = dataset_id

    def path(self, name: str) -> str:
        return os.path.join(self.dir, name)

    def exists(self) -> bool:
        return os.path.exists(self.path("dataset.json"))

    def hold(self) -> None:
        """Lock this dataset folder for the rest of the command (released when the process ends).

        bench-results-sync skips a held folder, so records are never moved to the results
        volume while a command is still writing them.
        """
        os.makedirs(self.dir, exist_ok=True)
        self._lock = open(self.path(".lock"), "a")
        try:
            fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise RuntimeError(f"dataset {self.id} is in use by another command")

    def load(self) -> dict:
        with open(self.path("dataset.json")) as fh:
            return json.load(fh)

    def save(self, meta: dict) -> None:
        os.makedirs(self.dir, exist_ok=True)
        tmp = self.path("dataset.json.tmp")
        with open(tmp, "w") as fh:
            json.dump(meta, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, self.path("dataset.json"))

    def write_manifest(self, gen: int, entries: list) -> str:
        os.makedirs(self.dir, exist_ok=True)
        name = f"manifest-g{gen}.csv.gz"
        with gzip.open(self.path(name), "wt", newline="") as fh:
            writer = csv.DictWriter(fh, MANIFEST_FIELDS, extrasaction="ignore")
            writer.writeheader()
            for e in sorted(entries, key=lambda e: e["idx"]):
                writer.writerow({"sha256": "", "state": "present", **e})
        return name

    def read_manifest(self, gen: int) -> list:
        with gzip.open(self.path(f"manifest-g{gen}.csv.gz"), "rt", newline="") as fh:
            return [
                {"idx": int(r["idx"]), "path": r["path"], "size": int(r["size"]),
                 "sha256": r["sha256"], "state": r["state"]}
                for r in csv.DictReader(fh)
            ]


def percentile(sorted_values: list, p: float) -> int:
    if not sorted_values:
        return 0
    rank = max(1, -(-len(sorted_values) * p // 100))  # nearest rank, rounded up
    return sorted_values[int(rank) - 1]


class Recorder:
    """Writes result rows to an ops file and keeps what the summary needs."""

    def __init__(self, path: str, total_tasks: int, quiet: bool = False):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._fh = gzip.open(path, "wt", newline="")
        self._writer = csv.DictWriter(self._fh, OPS_FIELDS, extrasaction="ignore")
        self._writer.writeheader()
        self.total_tasks, self.quiet = total_tasks, quiet
        self.rows: dict = {}          # idx -> row (latest)
        self.done = self.bytes = 0
        self.errors: list = []
        self.lat: dict = {}           # action -> field -> [us]
        self.counts: dict = {}
        self.start = self._last = time.time()

    def add(self, row: dict) -> None:
        self._writer.writerow(row)
        self.rows[row["idx"]] = row
        self.done += 1
        self.counts[row["action"]] = self.counts.get(row["action"], 0) + 1
        if row["error"]:
            self.errors.append((row["idx"], row["action"], row["error"]))
        else:
            self.bytes += row["bytes"]
            for field in TIMED:
                if row[field] != "":
                    self.lat.setdefault(row["action"], {}).setdefault(field, []).append(row[field])
        now = time.time()
        if not self.quiet and now - self._last >= 5:
            self._last = now
            rate = self.bytes / (now - self.start) / 1e6
            print(f"  {self.done}/{self.total_tasks} files, {self.bytes / 2**30:.2f} GiB, {rate:.1f} MB/s",
                  file=sys.stderr, flush=True)

    def close(self) -> dict:
        """Close the ops file and return the summary of this pass."""
        self._fh.close()
        wall = max(time.time() - self.start, 1e-9)
        latency = {}
        for action, fields in self.lat.items():
            latency[action] = {}
            for field, values in fields.items():
                values.sort()
                latency[action][field] = {
                    "count": len(values), "mean": round(sum(values) / len(values), 1),
                    "p50": percentile(values, 50), "p90": percentile(values, 90),
                    "p99": percentile(values, 99), "p99.9": percentile(values, 99.9), "max": values[-1],
                }
        return {
            "wall_s": round(wall, 3), "operations": self.counts, "bytes": self.bytes,
            "throughput_bytes_per_s": round(self.bytes / wall), "files_per_s": round(self.done / wall, 1),
            "errors": len(self.errors), "latency_us": latency,
        }


def mount_of(path: str):
    """The /proc/mounts line that holds `path` (device, type, options). None where there is no /proc."""
    try:
        with open("/proc/mounts") as fh:
            lines = [line.split() for line in fh]
    except OSError:
        return None
    real = os.path.realpath(path)
    best = None
    for dev, mnt, fstype, opts, *_ in lines:
        mnt = mnt.replace("\\040", " ")
        if real == mnt or real.startswith(mnt.rstrip("/") + "/"):
            if best is None or len(mnt) > len(best["mountpoint"]):
                best = {"device": dev, "mountpoint": mnt, "type": fstype, "options": opts}
    return best
