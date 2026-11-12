"""Push a test's metrics to Amazon CloudWatch AFTER the test, from the staged results.

Called by bench-results-sync before it copies the staging folder to the results volume, so
nothing extra happens during a test. What it sends (namespace $BENCH_CLOUDWATCH_NAMESPACE,
default FlexCacheBench; dimensions Lab, Side and the ones listed):

  from the Collector's telemetry (one statistic set per minute):
    CpuBusyPercent, MemoryUsedPercent, LoadAverage1m
    NetworkBytesPerSecond          Direction (all interfaces but lo)
    NfsOpsPerSecond, NfsRttMs, NfsExecuteMs        Mount, Op
    NfsBytesPerSecond              Mount, Direction
    EnaAllowanceExceeded           Counter
    PingRttMs, PingLossPercent     Target
  from bench-ontap (both clusters, polled by the origin client):
    OntapIops, OntapLatencyUs, OntapThroughputBytes   Cluster, Volume, Op (read/write/other/total)
    OntapNfsOps, OntapNfsLatencyUs                    Cluster, Volume, Op (main NFS operations)
    FlexCacheMissPercent, FlexCacheRequestedBlocks, FlexCacheMissBlocks   Cluster, Volume
    FsPingMs                       From, To, Method: latency between the file systems (ONTAP)
    InterclusterPingMs             Cluster, Target: ICMP from the origin client (fallback)
  from each dataset's per-file timings (one entry per minute):
    DatasetBytesWritten, DatasetFilesWritten       Dataset
    DatasetOpenLatency, DatasetWriteTime, DatasetCloseLatency (values, so CloudWatch can show
                                                   p50 / p99)  Dataset
  from each read pass (bench-dataset read), per minute:
    DatasetBytesRead, DatasetFilesRead             Dataset, Pass
    DatasetReadOpenLatency, DatasetFirstByteLatency, DatasetReadTime (whole file),
    DatasetReadCloseLatency (values: p50 / p99)    Dataset, Pass

Only whole minutes in the past are sent, never older than CloudWatch accepts (2 weeks). A cursor
file remembers what was sent, so nothing is sent twice; if a push fails, the cursor isn't moved
and the same minutes go next time. Sends with the AWS CLI, through the VPC's CloudWatch endpoint.
"""
from __future__ import annotations

import csv
import glob
import gzip
import json
import os
import subprocess
import tempfile
import time
from collections import defaultdict

NAMESPACE = "FlexCacheBench"
MAX_AGE_S = 14 * 86400 - 3600     # CloudWatch accepts data up to 2 weeks old
BATCH = 500                       # entries per PutMetricData call (limit 1000 and 1 MB)
MAX_VALUES = 150                  # distinct values per entry (CloudWatch limit)
PUSH_OPS = {"READ", "WRITE", "COMMIT", "GETATTR", "SETATTR", "LOOKUP", "ACCESS", "OPEN", "CLOSE",
            "CREATE", "REMOVE", "RENAME", "READDIR", "READDIRPLUS"}
ONTAP_NFS_OPS = {"getattr", "lookup", "access", "open", "read", "write", "readdir", "create_file", "setattr"}
ONTAP_SIMPLE = {   # bench-ontap metric -> (CloudWatch name, unit, extra dimensions besides Cluster)
    "ontap.volume.ops": ("OntapIops", "Count/Second", ("volume", "op")),
    "ontap.volume.latency": ("OntapLatencyUs", "Microseconds", ("volume", "op")),
    "ontap.volume.throughput": ("OntapThroughputBytes", "Bytes/Second", ("volume", "op")),
    "ontap.flexcache.miss_percent": ("FlexCacheMissPercent", "Percent", ("volume",)),
    "ontap.flexcache.requested_blocks": ("FlexCacheRequestedBlocks", "Count/Second", ("volume",)),
    "ontap.flexcache.miss_blocks": ("FlexCacheMissBlocks", "Count/Second", ("volume",)),
    "ontap.intercluster.ping_rtt": ("InterclusterPingMs", "Milliseconds", ("target",)),
}


# ------------------------------------------------------------------ reading OTLP JSON lines

def _attrs(items) -> dict:
    out = {}
    for a in items or []:
        v = a.get("value", {})
        out[a["key"]] = next(iter(v.values()), "") if v else ""
    return out


def _value(dp):
    if "asDouble" in dp:
        return float(dp["asDouble"])
    if "asInt" in dp:
        return float(dp["asInt"])
    return None


def read_otlp(paths):
    """Yield (metric name, unix seconds, value, attributes) from Collector file-exporter output."""
    for path in paths:
        try:
            fh = open(path)
        except OSError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    doc = json.loads(line)
                except ValueError:
                    continue      # the last line of the active file can be half written
                for rm in doc.get("resourceMetrics", []):
                    for sm in rm.get("scopeMetrics", []):
                        for m in sm.get("metrics", []):
                            body = m.get("gauge") or m.get("sum")
                            if not body:
                                continue
                            for dp in body.get("dataPoints", []):
                                v = _value(dp)
                                if v is not None:
                                    yield m["name"], int(dp.get("timeUnixNano", 0)) / 1e9, v, _attrs(dp.get("attributes"))


# ------------------------------------------------------------------ mapping to CloudWatch series

def series_from_telemetry(points):
    """[(metric, unit, dims tuple, unix seconds, value)] from read_otlp() output."""
    out = []
    cpu_idle = defaultdict(list)            # ts -> idle fraction per cpu
    net = defaultdict(dict)                  # (device, direction) -> {ts: cumulative bytes}
    for name, ts, v, a in points:
        if name == "system.cpu.utilization":
            if a.get("state") == "idle":
                cpu_idle[round(ts)].append(v)
        elif name == "system.memory.utilization":
            if a.get("state") == "used":
                out.append(("MemoryUsedPercent", "Percent", (), ts, v * 100))
        elif name == "system.cpu.load_average.1m":
            out.append(("LoadAverage1m", "None", (), ts, v))
        elif name == "system.network.io":
            if a.get("device") not in (None, "lo"):
                net[(a["device"], a.get("direction", ""))][ts] = v
        elif name in ("bench.nfs.ops", "bench.nfs.rtt", "bench.nfs.execute"):
            if a.get("op") in PUSH_OPS:
                metric, unit = {"bench.nfs.ops": ("NfsOpsPerSecond", "Count/Second"),
                                "bench.nfs.rtt": ("NfsRttMs", "Milliseconds"),
                                "bench.nfs.execute": ("NfsExecuteMs", "Milliseconds")}[name]
                out.append((metric, unit, (("Mount", a.get("mount", "")), ("Op", a["op"])), ts, v))
        elif name == "bench.nfs.bytes":
            out.append(("NfsBytesPerSecond", "Bytes/Second",
                        (("Mount", a.get("mount", "")), ("Direction", a.get("direction", ""))), ts, v))
        elif name == "bench.ena.allowance_exceeded":
            out.append(("EnaAllowanceExceeded", "Count", (("Counter", a.get("counter", "")),), ts, v))
        elif name == "bench.ping.rtt":
            out.append(("PingRttMs", "Milliseconds", (("Target", a.get("target", "")),), ts, v))
        elif name == "bench.ping.loss":
            out.append(("PingLossPercent", "Percent", (("Target", a.get("target", "")),), ts, v))
        elif name == "ontap.fs.ping_rtt":
            out.append(("FsPingMs", "Milliseconds", (("From", a.get("from", "")), ("To", a.get("to", "")),
                                                     ("Method", a.get("method", ""))), ts, v))
        elif name in ONTAP_SIMPLE:
            metric, unit, extra = ONTAP_SIMPLE[name]
            dims = (("Cluster", a.get("cluster", "")),) + tuple((k.capitalize(), a.get(k, "")) for k in extra)
            out.append((metric, unit, dims, ts, v))
        elif name in ("ontap.volume.nfs.ops", "ontap.volume.nfs.latency"):
            if a.get("op") in ONTAP_NFS_OPS:
                metric, unit = (("OntapNfsOps", "Count/Second") if name.endswith("ops")
                                else ("OntapNfsLatencyUs", "Microseconds"))
                out.append((metric, unit, (("Cluster", a.get("cluster", "")), ("Volume", a.get("volume", "")),
                                           ("Op", a["op"])), ts, v))
    for ts, idle in cpu_idle.items():
        out.append(("CpuBusyPercent", "Percent", (), ts, 100 * (1 - sum(idle) / len(idle))))
    # Network: cumulative counters -> bytes per second, summed over interfaces.
    rate = defaultdict(float)
    for (_dev, direction), samples in net.items():
        times = sorted(samples)
        for t0, t1 in zip(times, times[1:]):
            delta = samples[t1] - samples[t0]
            if t1 > t0 and delta >= 0:
                rate[(direction, round(t1))] += delta / (t1 - t0)
    for (direction, ts), v in rate.items():
        out.append(("NetworkBytesPerSecond", "Bytes/Second", (("Direction", direction),), ts, v))
    return out


def _round_sig(x: float, digits: int) -> float:
    if x == 0:
        return 0.0
    from math import floor, log10
    return round(x, -int(floor(log10(abs(x)))) + digits - 1)


def values_counts(values, max_distinct=MAX_VALUES):
    """Compress a list of numbers into (Values, Counts) with at most max_distinct values."""
    for digits in (3, 2, 1):
        hist = defaultdict(int)
        for v in values:
            hist[_round_sig(v, digits)] += 1
        if len(hist) <= max_distinct:
            break
    items = sorted(hist.items())[:max_distinct]
    return [k for k, _ in items], [float(c) for _, c in items]


WRITE_METRICS = {"bytes": "DatasetBytesWritten", "files": "DatasetFilesWritten", "open": "DatasetOpenLatency",
                 "io": "DatasetWriteTime", "close": "DatasetCloseLatency"}
READ_METRICS = {"bytes": "DatasetBytesRead", "files": "DatasetFilesRead", "open": "DatasetReadOpenLatency",
                "first": "DatasetFirstByteLatency", "io": "DatasetReadTime", "close": "DatasetReadCloseLatency"}


def dataset_entries(ops_path: str, dataset_id: str, read_pass=None):
    """Per-minute entries from a dataset's ops file: writes (ops-g<N>.csv.gz, create/overwrite/append
    rows) or, with read_pass, one read pass (reads/ops-read-*.csv.gz, read rows)."""
    actions = ("read",) if read_pass else ("create", "overwrite", "append")
    names = READ_METRICS if read_pass else WRITE_METRICS
    per_min = defaultdict(lambda: {"bytes": 0.0, "files": 0, "open": [], "first": [], "io": [], "close": []})
    with gzip.open(ops_path, "rt", newline="") as fh:
        for r in csv.DictReader(fh):
            if r.get("error") or r.get("action") not in actions:
                continue
            m = per_min[int(float(r["ts"])) // 60 * 60]
            m["bytes"] += float(r["bytes"] or 0)
            m["files"] += 1
            for key in ("open", "first", "io", "close"):
                if r.get(f"{key}_us"):
                    m[key].append(float(r[f"{key}_us"]))
    dims = (("Dataset", dataset_id),) + ((("Pass", str(read_pass)),) if read_pass else ())
    out = []
    for minute, m in sorted(per_min.items()):
        out.append((names["bytes"], "Bytes", dims, minute, {"Sum": m["bytes"]}))
        out.append((names["files"], "Count", dims, minute, {"Sum": float(m["files"])}))
        for key in ("open", "first", "io", "close"):
            if key in names and m[key]:
                vals, counts = values_counts(m[key])
                out.append((names[key], "Microseconds", dims, minute, {"Values": vals, "Counts": counts}))
    return out


# ------------------------------------------------------------------ per-minute statistic sets

def per_minute(series, now: float, cursor: dict):
    """Group (metric, unit, dims, ts, value) into one statistic set per series and whole minute,
    skipping the current minute, anything at or before the cursor, and anything too old."""
    groups = defaultdict(list)
    current = int(now) // 60 * 60
    oldest = now - MAX_AGE_S
    for metric, unit, dims, ts, v in series:
        minute = int(ts) // 60 * 60
        key = f"{metric}|{'|'.join(f'{k}={x}' for k, x in dims)}"
        if minute >= current or minute < oldest or minute <= cursor.get(key, 0):
            continue
        groups[(key, metric, unit, dims, minute)].append(v)
    out = []
    for (key, metric, unit, dims, minute), vals in groups.items():
        stats = {"SampleCount": float(len(vals)), "Sum": float(sum(vals)),
                 "Minimum": float(min(vals)), "Maximum": float(max(vals))}
        out.append((key, metric, unit, dims, minute, stats))
    return out


def _datum(metric, unit, dims, minute, values, base_dims):
    d = {"MetricName": metric, "Unit": unit, "StorageResolution": 60,
         "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(minute)),
         "Dimensions": [{"Name": k, "Value": str(v)} for k, v in base_dims + tuple(dims)]}
    if "Values" in values:
        d["Values"], d["Counts"] = values["Values"], values["Counts"]
    elif "SampleCount" in values:
        d["StatisticValues"] = values
    else:          # a plain sum for the minute
        d["StatisticValues"] = {"SampleCount": 1.0, "Sum": values["Sum"], "Minimum": values["Sum"], "Maximum": values["Sum"]}
    return d


def put(data, namespace: str, region: str, runner=subprocess.run) -> int:
    """Send datums with `aws cloudwatch put-metric-data`, BATCH at a time. Raises on failure."""
    sent = 0
    for i in range(0, len(data), BATCH):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"Namespace": namespace, "MetricData": data[i:i + BATCH]}, fh)
            path = fh.name
        try:
            r = runner(["aws", "cloudwatch", "put-metric-data", "--region", region,
                        "--cli-input-json", f"file://{path}"], capture_output=True, text=True, timeout=120)
        finally:
            os.unlink(path)
        if r.returncode != 0:
            raise RuntimeError((r.stderr or r.stdout or "put-metric-data failed").strip()[:400])
        sent += len(data[i:i + BATCH])
    return sent


# ------------------------------------------------------------------ the whole push

def push(staging: str, *, lab: str, side: str, region: str, namespace: str = NAMESPACE,
         cursor_path: str = "/var/lib/bench/cloudwatch-cursor.json", now=None, runner=subprocess.run) -> dict:
    """Push new telemetry minutes and not-yet-pushed dataset generations. Returns counts."""
    now = time.time() if now is None else now
    base = (("Lab", lab), ("Side", side))
    try:
        with open(cursor_path) as fh:
            cursor = json.load(fh)
    except (OSError, ValueError):
        cursor = {}

    files = sorted(glob.glob(os.path.join(staging, "telemetry", "**", "metrics*.json"), recursive=True))
    groups = per_minute(series_from_telemetry(read_otlp(files)), now, cursor)
    data = [_datum(metric, unit, dims, minute, stats, base) for _key, metric, unit, dims, minute, stats in groups]

    markers = []
    ops_files = [(p, os.path.basename(os.path.dirname(p)), None)
                 for p in sorted(glob.glob(os.path.join(staging, "datasets", "*", "ops-g*.csv.gz")))]
    for p in sorted(glob.glob(os.path.join(staging, "datasets", "*", "reads", "ops-read-*.csv.gz"))):
        pass_no = os.path.basename(p).split(".")[0].rsplit("-p", 1)[-1]
        ops_files.append((p, os.path.basename(os.path.dirname(os.path.dirname(p))), pass_no))
    for ops, ds, read_pass in ops_files:
        marker = os.path.join(os.path.dirname(ops), ".cloudwatch-" + os.path.basename(ops).split(".")[0])
        if os.path.exists(marker):
            continue
        for metric, unit, dims, minute, values in dataset_entries(ops, ds, read_pass):
            if now - MAX_AGE_S <= minute < int(now) // 60 * 60 + 60:
                data.append(_datum(metric, unit, dims, minute, values, base))
        markers.append(marker)

    sent = put(data, namespace, region, runner) if data else 0

    # Only after a successful push: move the cursor on and mark the datasets as sent.
    for key, _metric, _unit, _dims, minute, _stats in groups:
        cursor[key] = max(cursor.get(key, 0), minute)
    os.makedirs(os.path.dirname(cursor_path) or ".", exist_ok=True)
    tmp = cursor_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cursor, fh)
    os.replace(tmp, cursor_path)
    for marker in markers:
        open(marker, "w").close()
    return {"datums": sent, "series": len({g[0] for g in groups}), "datasets": len(markers)}
