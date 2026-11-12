"""bench-probe: NFS, network-limit and ping metrics for the local OpenTelemetry Collector.

The Collector's hostmetrics receiver covers CPU, memory, disk and network. This probe adds
what it can't see, and sends it to the Collector over OTLP/HTTP (JSON) every interval:

    bench.nfs.ops            NFS operations per second, per mount and operation (READ, GETATTR, ...)
    bench.nfs.rtt            average round-trip time per operation, ms (time on the wire + server)
    bench.nfs.execute        average execute time per operation, ms (includes client queueing)
    bench.nfs.bytes          bytes per second actually read / written to the server, per mount
    bench.ena.allowance_exceeded   packets queued or dropped because an EC2 network limit was hit
    bench.ping.rtt           ICMP round-trip time to each target, ms
    bench.ping.loss          ICMP packet loss to each target, %

Runs as root (systemd unit bench-probe, installed by modules/11-bench-telemetry):
    python3 -m bench.telemetry.probe --config /etc/bench/probe.json
Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request

DEFAULTS = {
    "interval_s": 5,
    "ping_interval_s": 10,
    "otlp_endpoint": "http://127.0.0.1:4318/v1/metrics",
    "mount_prefixes": ["/mnt/fsxn", "/mnt/bench"],
    "ping_targets": {},
    "interface": "",           # "" = the interface of the default route
}
ALWAYS_OPS = ("READ", "WRITE", "GETATTR", "LOOKUP", "ACCESS", "OPEN", "CLOSE")
ENA_COUNTERS = ("bw_in_allowance_exceeded", "bw_out_allowance_exceeded", "pps_allowance_exceeded",
                "conntrack_allowance_exceeded", "linklocal_allowance_exceeded")


def log(msg: str) -> None:
    print(f"bench-probe: {msg}", file=sys.stderr, flush=True)


# ------------------------------------------------------------------ NFS mountstats

def parse_mountstats(text: str, prefixes) -> dict:
    """{mountpoint: {"vers": "3", "server": "10.0.0.1:/vol", "bytes": {...}, "ops": {OP: (ops, rtt_ms, exe_ms)}}}.

    Counters are cumulative since mount; only NFS mounts under `prefixes` are kept.
    """
    mounts, cur = {}, None
    in_ops = False
    for line in text.splitlines():
        if line.startswith("device "):
            m = re.match(r"device (\S+) mounted on (\S+) with fstype (\S+)", line)
            cur, in_ops = None, False
            if m and m.group(3).startswith("nfs"):
                point = m.group(2).replace("\\040", " ")
                if any(point == p or point.startswith(p.rstrip("/") + "/") for p in prefixes):
                    cur = mounts[point] = {"server": m.group(1), "fstype": m.group(3), "vers": "",
                                           "bytes": {}, "ops": {}}
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("opts:"):
            v = re.search(r"\bvers=([0-9.]+)", s)
            cur["vers"] = v.group(1) if v else ("4" if cur["fstype"] == "nfs4" else "3")
        elif s.startswith("bytes:"):
            f = [int(x) for x in s.split()[1:]]
            if len(f) >= 6:
                cur["bytes"] = {"read": f[4], "write": f[5]}     # serverread, serverwrite
        elif s == "per-op statistics":
            in_ops = True
        elif in_ops and ":" in s:
            name, rest = s.split(":", 1)
            f = rest.split()
            if len(f) >= 8 and name.isupper():
                cur["ops"][name] = (int(f[0]), int(f[6]), int(f[7]))  # ops, rtt ms, execute ms
    return mounts


def nfs_rates(prev: dict, now: dict, seconds: float) -> list:
    """Per-interval metrics from two parse_mountstats() snapshots."""
    out = []
    for point, cur in now.items():
        old = prev.get(point)
        if not old:
            continue
        base = {"mount": point, "server": cur["server"], "nfs.version": cur["vers"]}
        for direction in ("read", "write"):
            if direction in cur["bytes"] and direction in old["bytes"]:
                delta = cur["bytes"][direction] - old["bytes"][direction]
                if delta >= 0:
                    out.append(("bench.nfs.bytes", "By/s", delta / seconds, {**base, "direction": direction}))
        for op, (ops, rtt, exe) in cur["ops"].items():
            o_ops, o_rtt, o_exe = old["ops"].get(op, (0, 0, 0))
            d_ops = ops - o_ops
            if d_ops < 0:          # remounted: counters restarted
                continue
            if d_ops == 0 and op not in ALWAYS_OPS:
                continue
            attrs = {**base, "op": op}
            out.append(("bench.nfs.ops", "{ops}/s", d_ops / seconds, attrs))
            if d_ops > 0:
                out.append(("bench.nfs.rtt", "ms", (rtt - o_rtt) / d_ops, attrs))
                out.append(("bench.nfs.execute", "ms", (exe - o_exe) / d_ops, attrs))
    return out


# ------------------------------------------------------------------ ENA allowance counters

def default_interface(route_text: str) -> str:
    for line in route_text.splitlines()[1:]:
        f = line.split()
        if len(f) > 2 and f[1] == "00000000":
            return f[0]
    return ""


def parse_ethtool(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        if ":" in line:
            k, v = line.strip().split(":", 1)
            if k in ENA_COUNTERS and v.strip().isdigit():
                out[k] = int(v.strip())
    return out


def ena_deltas(prev: dict, now: dict, iface: str) -> list:
    return [("bench.ena.allowance_exceeded", "{packets}", now[k] - prev[k], {"interface": iface, "counter": k})
            for k in now if k in prev and now[k] >= prev[k]]


# ------------------------------------------------------------------ ping

def parse_ping(text: str):
    """(avg rtt ms or None, loss %) from `ping -q` output."""
    loss = re.search(r"([0-9.]+)% packet loss", text)
    rtt = re.search(r"= [0-9.]+/([0-9.]+)/", text)
    return (float(rtt.group(1)) if rtt else None, float(loss.group(1)) if loss else 100.0)


def ping(ip: str):
    try:
        r = subprocess.run(["ping", "-c", "3", "-i", "0.2", "-W", "1", "-q", ip],
                           capture_output=True, text=True, timeout=10)
        return parse_ping(r.stdout)
    except (OSError, subprocess.TimeoutExpired):
        return None, 100.0


# ------------------------------------------------------------------ OTLP/HTTP JSON

def _attr(k, v):
    return {"key": k, "value": {"stringValue": str(v)}}


def otlp_payload(points: list, ts_ns: int) -> dict:
    """points = [(name, unit, value, {attrs})] -> OTLP JSON ExportMetricsServiceRequest of gauges."""
    by_name: dict = {}
    for name, unit, value, attrs in points:
        m = by_name.setdefault(name, {"name": name, "unit": unit, "gauge": {"dataPoints": []}})
        m["gauge"]["dataPoints"].append({
            "timeUnixNano": str(ts_ns), "asDouble": float(value),
            "attributes": [_attr(k, v) for k, v in sorted(attrs.items())],
        })
    return {"resourceMetrics": [{
        "resource": {"attributes": [_attr("service.name", "bench-probe")]},
        "scopeMetrics": [{"scope": {"name": "bench.telemetry.probe", "version": "1"},
                          "metrics": list(by_name.values())}],
    }]}


def send(endpoint: str, payload: dict) -> bool:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(endpoint, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return 200 <= resp.status < 300
    except OSError as exc:
        log(f"could not send to {endpoint}: {exc}")
        return False


# ------------------------------------------------------------------ main loop

def _read(path: str) -> str:
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return ""


def _ethtool(iface: str):
    try:
        r = subprocess.run(["ethtool", "-S", iface], capture_output=True, text=True, timeout=5)
        return parse_ethtool(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def _ping_loop(cfg: dict, stop: threading.Event) -> None:
    targets = cfg["ping_targets"]
    while targets and not stop.is_set():
        start = time.time()
        points = []
        for name, ip in targets.items():
            rtt, loss = ping(ip)
            attrs = {"target": name, "ip": ip}
            if rtt is not None:
                points.append(("bench.ping.rtt", "ms", rtt, attrs))
            points.append(("bench.ping.loss", "%", loss, attrs))
        send(cfg["otlp_endpoint"], otlp_payload(points, time.time_ns()))
        stop.wait(max(0.0, cfg["ping_interval_s"] - (time.time() - start)))


def run(cfg: dict, once: bool = False) -> None:
    iface = cfg["interface"] or default_interface(_read("/proc/net/route"))
    prev_nfs, prev_ena, prev_t = parse_mountstats(_read("/proc/self/mountstats"), cfg["mount_prefixes"]), None, time.time()
    if iface:
        prev_ena = _ethtool(iface)
        if prev_ena is None:
            log(f"ethtool -S {iface} not available: no ENA allowance metrics")
    stop = threading.Event()
    threading.Thread(target=_ping_loop, args=(cfg, stop), daemon=True).start()
    log(f"running every {cfg['interval_s']} s, interface {iface or 'none'}, "
        f"ping {', '.join(cfg['ping_targets']) or 'none'}, sending to {cfg['otlp_endpoint']}")
    while True:
        time.sleep(cfg["interval_s"])
        now_t = time.time()
        nfs = parse_mountstats(_read("/proc/self/mountstats"), cfg["mount_prefixes"])
        points = nfs_rates(prev_nfs, nfs, now_t - prev_t)
        if prev_ena is not None:
            ena = _ethtool(iface)
            if ena is not None:
                points += ena_deltas(prev_ena, ena, iface)
                prev_ena = ena
        prev_nfs, prev_t = nfs, now_t
        if points:
            send(cfg["otlp_endpoint"], otlp_payload(points, time.time_ns()))
        if once:
            stop.set()
            return


def load_config(path) -> dict:
    cfg = dict(DEFAULTS)
    if path:
        with open(path) as fh:
            cfg.update(json.load(fh))
    return cfg


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="bench-probe", description=__doc__.splitlines()[0])
    p.add_argument("--config", default="/etc/bench/probe.json" if os.path.exists("/etc/bench/probe.json") else None)
    p.add_argument("--once", action="store_true", help="one interval, then exit (for checks)")
    args = p.parse_args(argv)
    try:
        run(load_config(args.config), once=args.once)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
