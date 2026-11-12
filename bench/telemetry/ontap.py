"""bench-ontap: ONTAP metrics from both FSx for ONTAP clusters, for the local OpenTelemetry Collector.

Runs on the origin client (it reaches both management IPs and may read the fsxadmin secret)
and sends OTLP/HTTP JSON to the Collector every interval, like bench-probe:

  per watched volume (vol_origin, vol_cache, vol_bench), from GET /api/storage/volumes?fields=statistics
  (cumulative counters, turned into per-interval rates and averages):
    ontap.volume.ops            operations per second          op = read | write | other | total
    ontap.volume.latency        average latency, microseconds  op = read | write | other | total
    ontap.volume.throughput     bytes per second               op = read | write | other | total
    ontap.volume.nfs.ops        NFS operations per second      op = getattr, lookup, read, ...
    ontap.volume.nfs.latency    average NFS latency, us        op = getattr, lookup, read, ...
  FlexCache volumes (statistics.flexcache_raw):
    ontap.flexcache.requested_blocks   blocks per second requested by clients
    ontap.flexcache.miss_blocks        blocks per second fetched from the origin (cache misses)
    ontap.flexcache.miss_percent       miss_blocks / requested_blocks * 100
  latency BETWEEN THE FILE SYSTEMS, measured by ONTAP itself, both directions:
    ontap.fs.ping_rtt           ms; from, to (origin | cache), method, path
        method network-ping       `network ping` from each intercluster LIF of one cluster to each
                                  intercluster IP of the other (REST CLI passthrough)
        method cluster-peer-ping  `cluster peer ping` (REST CLI passthrough)
      A method FSx refuses is logged once and switched off.
  and, as a fallback measured from this client (not between the file systems):
    ontap.intercluster.ping_rtt ICMP from this client to each cluster's intercluster IPs, ms

Every point carries cluster (origin | cache) and volume. Uses the fsxadmin credentials from
Secrets Manager. Standard library only.
    python3 -m bench.telemetry.ontap --config /etc/bench/ontap.json
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

from . import probe

DEFAULTS = {
    "interval_s": 15,
    "ping_interval_s": 30,
    "otlp_endpoint": "http://127.0.0.1:4318/v1/metrics",
    "secret": {},        # {"arn": ..., "region": ...}
    "clusters": {},      # {"origin": {"mgmt_ip": ..., "volumes": [...], "intercluster_ips": [...]}, "cache": {...}}
    "peer_ping": True,
}
OPS = ("read", "write", "other", "total")


def log(msg: str) -> None:
    print(f"bench-ontap: {msg}", file=sys.stderr, flush=True)


# ------------------------------------------------------------------ REST

def read_secret(arn: str, region: str):
    r = subprocess.run(["aws", "secretsmanager", "get-secret-value", "--secret-id", arn, "--region", region,
                        "--query", "SecretString", "--output", "text"], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f"cannot read the fsxadmin secret: {r.stderr.strip()[:200]}")
    s = json.loads(r.stdout)
    return s["username"], s["password"]


class Ontap:
    def __init__(self, host: str, user: str, password: str):
        self.base = f"https://{host}/api"
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}", "Accept": "application/json"}
        self.ctx = ssl._create_unverified_context()   # FSx management endpoint: self-signed certificate

    def get(self, path: str) -> dict:
        req = urllib.request.Request(self.base + path, headers=self.headers)
        with urllib.request.urlopen(req, context=self.ctx, timeout=20) as resp:
            return json.loads(resp.read() or b"{}")

    def post(self, path: str, body: dict) -> dict:
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(), method="POST",
                                     headers={**self.headers, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, context=self.ctx, timeout=60) as resp:
            return json.loads(resp.read() or b"{}")


# ------------------------------------------------------------------ volume counters -> rates

def _nfs_ops(raw: dict) -> dict:
    """nfs_ops_raw -> {op: (count, total_time_us)}; nested ops (create.file) become create_file."""
    out = {}
    for op, v in (raw or {}).items():
        if isinstance(v, dict) and "count" in v:
            out[op] = (int(v.get("count", 0)), int(v.get("total_time", 0)))
        elif isinstance(v, dict):
            for sub, w in v.items():
                if isinstance(w, dict) and "count" in w:
                    out[f"{op}_{sub}"] = (int(w.get("count", 0)), int(w.get("total_time", 0)))
    return out


def snapshot(records: list, now: float) -> dict:
    """{volume name: counters} from GET /storage/volumes?fields=name,statistics records."""
    out = {}
    for r in records:
        st = r.get("statistics") or {}
        fc = st.get("flexcache_raw") or {}
        out[r["name"]] = {
            "t": now,
            "iops": {k: int((st.get("iops_raw") or {}).get(k, 0)) for k in OPS},
            "latency": {k: int((st.get("latency_raw") or {}).get(k, 0)) for k in OPS},
            "throughput": {k: int((st.get("throughput_raw") or {}).get(k, 0)) for k in OPS},
            "nfs": _nfs_ops(st.get("nfs_ops_raw")),
            "flexcache": (int(fc.get("client_requested_blocks", 0)), int(fc.get("cache_miss_blocks", 0))) if fc else None,
        }
    return out


def volume_rates(cluster: str, prev: dict, now: dict) -> list:
    """Per-interval points from two snapshot() results of one cluster."""
    points = []
    for vol, cur in now.items():
        old = prev.get(vol)
        if not old or cur["t"] <= old["t"]:
            continue
        dt = cur["t"] - old["t"]
        base = {"cluster": cluster, "volume": vol}
        for op in OPS:
            d_ops = cur["iops"][op] - old["iops"][op]
            d_lat = cur["latency"][op] - old["latency"][op]
            d_bytes = cur["throughput"][op] - old["throughput"][op]
            if d_ops < 0 or d_bytes < 0:        # counters reset (failover, volume offline)
                continue
            a = {**base, "op": op}
            points.append(("ontap.volume.ops", "{ops}/s", d_ops / dt, a))
            points.append(("ontap.volume.throughput", "By/s", d_bytes / dt, a))
            if d_ops > 0 and d_lat >= 0:
                points.append(("ontap.volume.latency", "us", d_lat / d_ops, a))
        for op, (count, total) in cur["nfs"].items():
            o_count, o_total = old["nfs"].get(op, (0, 0))
            d_count, d_time = count - o_count, total - o_total
            if d_count <= 0 or d_time < 0:
                continue
            a = {**base, "op": op}
            points.append(("ontap.volume.nfs.ops", "{ops}/s", d_count / dt, a))
            points.append(("ontap.volume.nfs.latency", "us", d_time / d_count, a))
        if cur["flexcache"] and old["flexcache"]:
            d_req = cur["flexcache"][0] - old["flexcache"][0]
            d_miss = cur["flexcache"][1] - old["flexcache"][1]
            if d_req >= 0 and d_miss >= 0:
                points.append(("ontap.flexcache.requested_blocks", "{blocks}/s", d_req / dt, base))
                points.append(("ontap.flexcache.miss_blocks", "{blocks}/s", d_miss / dt, base))
                if d_req > 0:
                    points.append(("ontap.flexcache.miss_percent", "%", 100.0 * d_miss / d_req, base))
    return points


# ------------------------------------------------------------------ latency between the file systems

_MIN_AVG_MAX = re.compile(r"=\s*([\d.]+)/([\d.]+)/([\d.]+)")      # rtt min/avg/max = 0.4/0.5/0.7 ms
_TIME = re.compile(r"time[=<]\s*([\d.]+)\s*ms")                   # ... time=0.52 ms
_PEER_LINE = re.compile(r"(\d+\.\d+\.\d+\.\d+)\s+\d+\s+\d+\s+([\d.]+)")   # ip count ttl rtt(ms) ...


def parse_ping_text(text: str):
    """Average RTT in ms from ping output text, or None."""
    m = _MIN_AVG_MAX.search(text or "")
    if m:
        return float(m.group(2))
    times = [float(t) for t in _TIME.findall(text or "")]
    return sum(times) / len(times) if times else None


def peer_ping_rtts(body: dict) -> list:
    """[(path, rtt ms)] from a `cluster peer ping` passthrough response: records (GET), whose
    field names vary by release (any numeric field containing "rtt"), or the CLI text (POST)."""
    out = []
    for r in body.get("records", []) or []:
        for k, v in r.items():
            if "rtt" in k.lower():
                try:
                    rtt = float(str(v).split()[0])
                except (ValueError, IndexError):
                    continue
                src = r.get("originating_node", r.get("originating-node", ""))
                dst = r.get("destination_node", r.get("destination-node", r.get("ip_address", "")))
                out.append((f"{src}->{dst}", rtt))
    for line in (body.get("cli_output") or "").splitlines():
        m = _PEER_LINE.search(line)
        if m:
            out.append((f"->{m.group(1)}", float(m.group(2))))
    return out


class FsPing:
    """Measures the latency between the two file systems with ONTAP's own tools."""

    def __init__(self, clusters_cfg: dict):
        self.cfg = clusters_cfg
        self.methods = {"network-ping": True, "cluster-peer-ping": True}
        self.lifs = {}          # cluster -> (cluster name, [(lif, ip, node)])
        self.warned = set()

    def _failed(self, method: str, exc) -> None:
        """Refused by ONTAP (HTTP 4xx): not available on this FSx, switch it off. Anything else
        (timeout, network): log once and try again next round."""
        if isinstance(exc, urllib.error.HTTPError) and 400 <= exc.code < 500:
            if self.methods.get(method):
                log(f"{method} between the file systems is not available on this FSx ({exc}); switched off")
            self.methods[method] = False
        elif method not in self.warned:
            log(f"{method} between the file systems failed this time ({exc}); retrying")
            self.warned.add(method)

    def _discover(self, side: str, api) -> tuple:
        if side not in self.lifs:
            name = api.get("/cluster?fields=name").get("name", "")
            recs = api.get("/network/ip/interfaces?services=intercluster_core&fields=name,ip.address,location.node.name")
            lifs = [(r["name"], r.get("ip", {}).get("address", ""), r.get("location", {}).get("node", {}).get("name", ""))
                    for r in recs.get("records", [])]
            self.lifs[side] = (name, lifs)
        return self.lifs[side]

    def points(self, clients: dict) -> list:
        out = []
        for src, api in clients.items():
            for dst, other in self.cfg.items():
                if dst == src:
                    continue
                if self.methods["network-ping"]:
                    try:
                        name, lifs = self._discover(src, api)
                        for lif, _ip, node in lifs:
                            for ip in other.get("intercluster_ips", []):
                                resp = api.post("/private/cli/network/ping", {
                                    "vserver": name, "lif": lif, "destination": ip, "show_detail": True, "count": 3})
                                rtt = parse_ping_text(resp.get("cli_output") or json.dumps(resp))
                                if rtt is not None:
                                    out.append(("ontap.fs.ping_rtt", "ms", rtt, {
                                        "from": src, "to": dst, "method": "network-ping", "path": f"{node}/{lif}->{ip}"}))
                    except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
                        self._failed("network-ping", exc)
                if self.methods["cluster-peer-ping"]:
                    try:
                        try:
                            body = api.get("/private/cli/cluster/peer/ping")
                        except urllib.error.HTTPError as exc:
                            if exc.code not in (400, 404, 405):
                                raise
                            body = api.post("/private/cli/cluster/peer/ping", {})
                        for path, rtt in peer_ping_rtts(body):
                            out.append(("ontap.fs.ping_rtt", "ms", rtt, {
                                "from": src, "to": dst, "method": "cluster-peer-ping", "path": path}))
                    except (urllib.error.URLError, OSError, ValueError) as exc:
                        self._failed("cluster-peer-ping", exc)
        return out


# ------------------------------------------------------------------ main loop

def run(cfg: dict, once: bool = False) -> None:
    user, password = read_secret(cfg["secret"]["arn"], cfg["secret"]["region"])
    clients = {name: Ontap(c["mgmt_ip"], user, password) for name, c in cfg["clusters"].items()}
    prev = {name: {} for name in clients}
    fs_ping = FsPing(cfg["clusters"])
    last_ping = 0.0
    warned = set()
    watched = "; ".join(n + ": " + ", ".join(c.get("volumes", [])) for n, c in cfg["clusters"].items())
    log(f"watching {watched}; every {cfg['interval_s']} s, sending to {cfg['otlp_endpoint']}")
    while True:
        start = time.time()
        points = []
        for name, api in clients.items():
            vols = cfg["clusters"][name].get("volumes", [])
            if not vols:
                continue
            try:
                body = api.get("/storage/volumes?fields=name,svm.name,statistics&name=" + "|".join(vols))
                snap = snapshot(body.get("records", []), time.time())
                points += volume_rates(name, prev[name], snap)
                prev[name] = snap
                warned.discard(f"vol-{name}")
            except (urllib.error.URLError, OSError, ValueError) as exc:
                if isinstance(exc, urllib.error.HTTPError) and exc.code == 401:
                    user, password = read_secret(cfg["secret"]["arn"], cfg["secret"]["region"])
                    clients = {n: Ontap(c["mgmt_ip"], user, password) for n, c in cfg["clusters"].items()}
                if f"vol-{name}" not in warned:
                    log(f"{name}: volume statistics failed: {exc}")
                    warned.add(f"vol-{name}")

        if time.time() - last_ping >= cfg["ping_interval_s"]:
            last_ping = time.time()
            if cfg.get("peer_ping", True):
                points += fs_ping.points(clients)
            for name, c in cfg["clusters"].items():
                for i, ip in enumerate(c.get("intercluster_ips", [])):
                    rtt, loss = probe.ping(ip)
                    attrs = {"cluster": name, "target": f"{name}-intercluster-{i + 1}", "ip": ip, "from": "origin-client"}
                    if rtt is not None:
                        points.append(("ontap.intercluster.ping_rtt", "ms", rtt, attrs))
                    points.append(("ontap.intercluster.ping_loss", "%", loss, attrs))

        if points:
            probe.send(cfg["otlp_endpoint"], probe.otlp_payload(points, time.time_ns()))
        if once:
            return
        time.sleep(max(1.0, cfg["interval_s"] - (time.time() - start)))


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="bench-ontap", description=__doc__.splitlines()[0])
    p.add_argument("--config", default="/etc/bench/ontap.json")
    p.add_argument("--once", action="store_true", help="one round, then exit (rates need two rounds)")
    args = p.parse_args(argv)
    cfg = dict(DEFAULTS)
    with open(args.config) as fh:
        cfg.update(json.load(fh))
    try:
        run(cfg, once=args.once)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
