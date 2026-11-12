"""Run: python3 -m unittest discover -s bench/tests -t ."""
import unittest

from bench.results import cloudwatch as cw
from bench.telemetry import ontap


def record(name, iops, lat, thr, nfs=None, fc=None):
    """A /storage/volumes record shaped like the ONTAP REST reference (statistics.*_raw)."""
    st = {
        "iops_raw": dict(zip(("read", "write", "other", "total"), iops)),
        "latency_raw": dict(zip(("read", "write", "other", "total"), lat)),
        "throughput_raw": dict(zip(("read", "write", "other", "total"), thr)),
        "status": "ok", "timestamp": "2026-11-12 10:00:00 +0000",
    }
    if nfs:
        st["nfs_ops_raw"] = nfs
    if fc:
        st["flexcache_raw"] = {"client_requested_blocks": fc[0], "cache_miss_blocks": fc[1], "status": "ok"}
    return {"name": name, "svm": {"name": "svm"}, "statistics": st}


class Rates(unittest.TestCase):
    def setUp(self):
        a = [record("vol_cache", (100, 50, 10, 160), (20000, 50000, 1000, 71000), (1_000_000, 500_000, 0, 1_500_000),
                    nfs={"getattr": {"count": 100, "total_time": 3000},
                         "create": {"file": {"count": 10, "total_time": 900}, "dir": {"count": 0, "total_time": 0}}},
                    fc=(1000, 100))]
        b = [record("vol_cache", (400, 50, 10, 460), (80000, 50000, 1000, 131000), (4_000_000, 500_000, 0, 4_500_000),
                    nfs={"getattr": {"count": 300, "total_time": 7000},
                         "create": {"file": {"count": 20, "total_time": 2900}, "dir": {"count": 0, "total_time": 0}}},
                    fc=(4000, 400))]
        self.points = ontap.volume_rates("cache", ontap.snapshot(a, 100.0), ontap.snapshot(b, 110.0))
        self.p = {(n, at.get("op")): v for n, _u, v, at in self.points}

    def test_volume_rates_and_latency(self):
        self.assertAlmostEqual(self.p[("ontap.volume.ops", "read")], 30.0)            # 300 ops / 10 s
        self.assertAlmostEqual(self.p[("ontap.volume.latency", "read")], 200.0)       # 60000 us / 300 ops
        self.assertAlmostEqual(self.p[("ontap.volume.throughput", "read")], 300000.0)
        self.assertEqual(self.p[("ontap.volume.ops", "write")], 0.0)
        self.assertNotIn(("ontap.volume.latency", "write"), self.p)                 # no ops: no average
        self.assertTrue(all(at["cluster"] == "cache" and at["volume"] == "vol_cache" for *_x, at in self.points))

    def test_nfs_ops_including_nested(self):
        self.assertAlmostEqual(self.p[("ontap.volume.nfs.ops", "getattr")], 20.0)
        self.assertAlmostEqual(self.p[("ontap.volume.nfs.latency", "getattr")], 20.0)  # 4000 us / 200
        self.assertAlmostEqual(self.p[("ontap.volume.nfs.latency", "create_file")], 200.0)
        self.assertNotIn(("ontap.volume.nfs.ops", "create_dir"), self.p)            # idle ops left out

    def test_flexcache(self):
        self.assertAlmostEqual(self.p[("ontap.flexcache.requested_blocks", None)], 300.0)
        self.assertAlmostEqual(self.p[("ontap.flexcache.miss_blocks", None)], 30.0)
        self.assertAlmostEqual(self.p[("ontap.flexcache.miss_percent", None)], 10.0)

    def test_counter_reset_is_skipped(self):
        a = ontap.snapshot([record("v", (500, 0, 0, 500), (1, 0, 0, 1), (10, 0, 0, 10))], 1.0)
        b = ontap.snapshot([record("v", (5, 0, 0, 5), (1, 0, 0, 1), (1, 0, 0, 1))], 2.0)
        self.assertFalse([p for p in ontap.volume_rates("origin", a, b) if p[3].get("op") == "read"])

    def test_peer_ping_and_ping_text(self):
        self.assertEqual(ontap.peer_ping_rtts({"records": [
            {"originating_node": "n1", "destination_node": "c1", "rtt": "1.25"},
            {"originating_node": "n1", "destination_node": "c2", "rtt": "bad"}]}), [("n1->c1", 1.25)])
        text = "Node: n1\nDestination Node IP Address      Count  TTL  RTT(ms) Status\nc1   10.20.1.8   1   255  1.874 interface_reachable\n"
        self.assertEqual(ontap.peer_ping_rtts({"cli_output": text}), [("->10.20.1.8", 1.874)])
        self.assertEqual(ontap.parse_ping_text("3 packets transmitted\nrtt min/avg/max = 0.4/0.52/0.7 ms"), 0.52)
        self.assertEqual(ontap.parse_ping_text("64 bytes: time=1.5 ms\n64 bytes: time=2.5 ms"), 2.0)
        self.assertIsNone(ontap.parse_ping_text("10.20.1.8 is alive"))

    def test_cloudwatch_mapping(self):
        s = cw.series_from_telemetry((n, 1000.0, v, at) for n, _u, v, at in self.points)
        names = {(m, d) for m, _u, d, _t, _v in s}
        self.assertIn(("OntapLatencyUs", (("Cluster", "cache"), ("Volume", "vol_cache"), ("Op", "read"))), names)
        self.assertIn(("FlexCacheMissPercent", (("Cluster", "cache"), ("Volume", "vol_cache"))), names)
        self.assertIn(("OntapNfsLatencyUs", (("Cluster", "cache"), ("Volume", "vol_cache"), ("Op", "create_file"))), names)


class Loop(unittest.TestCase):
    def test_two_rounds_with_fakes(self):
        import urllib.error
        calls, sent = [], []
        rounds = iter([1, 2])

        class FakeOntap:
            def __init__(self, host, user, password):
                self.host = host
                self.assertion = (user, password) == ("fsxadmin", "pw")

            def get(self, path):
                calls.append((self.host, path))
                if path.startswith("/private/cli"):
                    raise urllib.error.HTTPError(path, 403, "forbidden", {}, None)
                n = 1 if len([c for c in calls if c[0] == self.host and "volumes" in c[1]]) == 1 else 2
                return {"records": [record("vol_origin", (100 * n, 0, 0, 100 * n), (1000 * n, 0, 0, 1000 * n), (10 * n, 0, 0, 10 * n))]}

        orig = (ontap.Ontap, ontap.read_secret, ontap.probe.send, ontap.probe.ping, ontap.time.sleep, ontap.log)
        ontap.Ontap = FakeOntap
        ontap.read_secret = lambda arn, region: ("fsxadmin", "pw")
        ontap.probe.send = lambda url, payload: sent.append(payload) or True
        ontap.probe.ping = lambda ip: (0.8, 0.0)
        ontap.time.sleep = lambda s: None
        ontap.log = lambda m: None
        try:
            cfg = dict(ontap.DEFAULTS, secret={"arn": "a", "region": "r"},
                       clusters={"origin": {"mgmt_ip": "10.0.0.1", "volumes": ["vol_origin", "vol_bench"],
                                            "intercluster_ips": ["10.0.0.5"]}})
            ontap.run(cfg, once=True)
            ontap.run(cfg, once=True)
        finally:
            ontap.Ontap, ontap.read_secret, ontap.probe.send, ontap.probe.ping, ontap.time.sleep, ontap.log = orig
        self.assertIn(("10.0.0.1", "/storage/volumes?fields=name,svm.name,statistics&name=vol_origin|vol_bench"), calls)
        names = {m["name"] for p in sent for m in p["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]}
        self.assertIn("ontap.intercluster.ping_rtt", names)        # ICMP still measured without peer ping


class FsPingBothDirections(unittest.TestCase):
    def test_network_ping_both_ways_and_refused_peer_ping(self):
        import urllib.error
        posts = []

        class Api:
            def __init__(self, side):
                self.side = side

            def get(self, path):
                if path.startswith("/cluster"):
                    return {"name": f"{self.side}-cluster"}
                if path.startswith("/network/ip/interfaces"):
                    return {"records": [{"name": "inter_1", "ip": {"address": f"{self.side}-ic"},
                                         "location": {"node": {"name": f"{self.side}-01"}}}]}
                raise urllib.error.HTTPError(path, 403, "forbidden", {}, None)      # peer ping refused

            def post(self, path, body):
                posts.append((self.side, path, body))
                if "peer" in path:
                    raise urllib.error.HTTPError(path, 403, "forbidden", {}, None)
                return {"cli_output": "rtt min/avg/max = 1.0/1.5/2.0 ms"}

        old_log = ontap.log
        ontap.log = lambda m: None
        try:
            fp = ontap.FsPing({"origin": {"intercluster_ips": ["10.10.1.8"]}, "cache": {"intercluster_ips": ["10.20.1.8"]}})
            pts = fp.points({"origin": Api("origin"), "cache": Api("cache")})
            self.assertFalse(fp.methods["cluster-peer-ping"])          # refused: switched off
            self.assertTrue(fp.methods["network-ping"])
        finally:
            ontap.log = old_log
        dirs = {(a["from"], a["to"], a["method"]) for _n, _u, _v, a in pts}
        self.assertEqual(dirs, {("origin", "cache", "network-ping"), ("cache", "origin", "network-ping")})
        self.assertTrue(all(v == 1.5 for _n, _u, v, _a in pts))
        body = next(b for side, p, b in posts if side == "origin" and "network/ping" in p)
        self.assertEqual((body["vserver"], body["lif"], body["destination"]), ("origin-cluster", "inter_1", "10.20.1.8"))

    def test_timeout_does_not_switch_off(self):
        import urllib.error

        class Api:
            def get(self, path):
                raise urllib.error.URLError("timed out")

            def post(self, path, body):
                raise urllib.error.URLError("timed out")

        old_log = ontap.log
        ontap.log = lambda m: None
        try:
            fp = ontap.FsPing({"origin": {}, "cache": {"intercluster_ips": ["x"]}})
            fp.points({"origin": Api()})
        finally:
            ontap.log = old_log
        self.assertTrue(fp.methods["network-ping"] and fp.methods["cluster-peer-ping"])

    def test_cloudwatch_name(self):
        s = cw.series_from_telemetry([("ontap.fs.ping_rtt", 1000.0, 1.5,
                                       {"from": "cache", "to": "origin", "method": "network-ping", "path": "p"})])
        self.assertEqual(s[0][:3], ("FsPingMs", "Milliseconds", (("From", "cache"), ("To", "origin"), ("Method", "network-ping"))))


if __name__ == "__main__":
    unittest.main()
