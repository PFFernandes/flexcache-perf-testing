"""Run: python3 -m unittest discover -s bench/tests -t ."""
import contextlib
import io
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from bench.telemetry import probe

# Trimmed from a real /proc/self/mountstats (Amazon Linux 2023, NFSv3 and NFSv4.1).
MOUNTSTATS_1 = """\
device proc mounted on /proc with fstype proc
device 10.10.1.5:/vol_origin mounted on /mnt/fsxn/vol_origin with fstype nfs statvers=1.1
\topts:\trw,vers=3,rsize=1048576,wsize=1048576,namlen=255,acregmin=3,hard,proto=tcp,nconnect=8
\tage:\t3600
\tbytes:\t100 200 0 0 1000 2000 10 20
\tRPC iostats version: 1.1  p/v: 100003/3 (nfs)
\txprt:\ttcp 0 1 1 0 0 10 10 0 10 0 2 0 0
\tper-op statistics
\t        NULL: 0 0 0 0 0 0 0 0 0
\t     GETATTR: 100 100 0 11200 11200 10 200 220 0
\t      LOOKUP: 50 50 0 6000 6000 5 100 110 0
\t        READ: 10 10 0 1200 10485760 2 30 35 0
\t       WRITE: 0 0 0 0 0 0 0 0 0
\t      COMMIT: 0 0 0 0 0 0 0 0 0
device 10.20.1.5:/vol_cache mounted on /mnt/fsxn/vol_cache with fstype nfs4 statvers=1.1
\topts:\trw,vers=4.1,rsize=1048576
\tbytes:\t0 0 0 0 0 0 0 0
\tper-op statistics
\t        OPEN: 4 4 0 900 900 1 20 22 0
device 10.10.1.5:/other mounted on /mnt/elsewhere with fstype nfs statvers=1.1
\topts:\trw,vers=3
\tper-op statistics
\t        READ: 999 999 0 0 0 0 9 9 0
"""
MOUNTSTATS_2 = MOUNTSTATS_1.replace(
    "GETATTR: 100 100 0 11200 11200 10 200 220 0", "GETATTR: 150 150 0 16800 16800 15 300 330 0").replace(
    "READ: 10 10 0 1200 10485760 2 30 35 0", "READ: 20 20 0 2400 20971520 4 50 60 0").replace(
    "bytes:\t100 200 0 0 1000 2000 10 20", "bytes:\t100 200 0 0 11000 2000 10 20")


class MountStats(unittest.TestCase):
    def test_parse(self):
        m = probe.parse_mountstats(MOUNTSTATS_1, ["/mnt/fsxn"])
        self.assertEqual(sorted(m), ["/mnt/fsxn/vol_cache", "/mnt/fsxn/vol_origin"])   # /mnt/elsewhere skipped
        o = m["/mnt/fsxn/vol_origin"]
        self.assertEqual(o["vers"], "3")
        self.assertEqual(o["server"], "10.10.1.5:/vol_origin")
        self.assertEqual(o["ops"]["GETATTR"], (100, 200, 220))
        self.assertEqual(o["bytes"], {"read": 1000, "write": 2000})
        self.assertEqual(m["/mnt/fsxn/vol_cache"]["vers"], "4.1")

    def test_rates(self):
        a = probe.parse_mountstats(MOUNTSTATS_1, ["/mnt/fsxn"])
        b = probe.parse_mountstats(MOUNTSTATS_2, ["/mnt/fsxn"])
        pts = {(n, at.get("op", at.get("direction")), at["mount"]): v for n, _, v, at in probe.nfs_rates(a, b, 5.0)}
        mnt = "/mnt/fsxn/vol_origin"
        self.assertAlmostEqual(pts[("bench.nfs.ops", "GETATTR", mnt)], 10.0)       # 50 ops / 5 s
        self.assertAlmostEqual(pts[("bench.nfs.rtt", "GETATTR", mnt)], 2.0)        # 100 ms / 50 ops
        self.assertAlmostEqual(pts[("bench.nfs.execute", "GETATTR", mnt)], 2.2)
        self.assertAlmostEqual(pts[("bench.nfs.ops", "READ", mnt)], 2.0)
        self.assertAlmostEqual(pts[("bench.nfs.rtt", "READ", mnt)], 2.0)
        self.assertAlmostEqual(pts[("bench.nfs.bytes", "read", mnt)], 2000.0)      # 10000 bytes / 5 s
        self.assertEqual(pts[("bench.nfs.ops", "WRITE", mnt)], 0.0)                # always reported
        self.assertNotIn(("bench.nfs.rtt", "WRITE", mnt), pts)                     # no ops, no average
        self.assertNotIn(("bench.nfs.ops", "COMMIT", mnt), pts)                    # idle and not in ALWAYS_OPS

    def test_remount_resets_counters(self):
        a = probe.parse_mountstats(MOUNTSTATS_2, ["/mnt/fsxn"])
        b = probe.parse_mountstats(MOUNTSTATS_1, ["/mnt/fsxn"])
        self.assertFalse([p for p in probe.nfs_rates(a, b, 5.0) if p[0] == "bench.nfs.ops" and p[3]["op"] == "GETATTR"])


class EnaAndPing(unittest.TestCase):
    def test_ethtool(self):
        text = "NIC statistics:\n     tx_timeout: 0\n     bw_in_allowance_exceeded: 3\n     pps_allowance_exceeded: 10\n"
        self.assertEqual(probe.parse_ethtool(text), {"bw_in_allowance_exceeded": 3, "pps_allowance_exceeded": 10})
        d = probe.ena_deltas({"bw_in_allowance_exceeded": 3}, {"bw_in_allowance_exceeded": 7}, "ens5")
        self.assertEqual(d, [("bench.ena.allowance_exceeded", "{packets}", 4,
                              {"interface": "ens5", "counter": "bw_in_allowance_exceeded"})])

    def test_default_interface(self):
        route = "Iface\tDestination\tGateway\nens5\t0001A8C0\t00000000\nens5\t00000000\t0101A8C0\n"
        self.assertEqual(probe.default_interface(route), "ens5")

    def test_ping(self):
        ok = "3 packets transmitted, 3 received, 0% packet loss, time 402ms\nrtt min/avg/max/mdev = 0.310/0.415/0.520/0.085 ms\n"
        self.assertEqual(probe.parse_ping(ok), (0.415, 0.0))
        self.assertEqual(probe.parse_ping("3 packets transmitted, 0 received, 100% packet loss\n"), (None, 100.0))


class Otlp(unittest.TestCase):
    def test_payload_shape(self):
        p = probe.otlp_payload([("bench.ping.rtt", "ms", 0.4, {"target": "origin-nfs"}),
                                ("bench.ping.rtt", "ms", 1.2, {"target": "cache-nfs"})], 1700000000000000000)
        metrics = p["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]
        self.assertEqual(len(metrics), 1)
        dps = metrics[0]["gauge"]["dataPoints"]
        self.assertEqual([d["asDouble"] for d in dps], [0.4, 1.2])
        self.assertEqual(dps[0]["timeUnixNano"], "1700000000000000000")
        self.assertEqual(dps[0]["attributes"], [{"key": "target", "value": {"stringValue": "origin-nfs"}}])

    def test_send_to_otlp_http(self):
        received = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append((self.path, self.headers["Content-Type"],
                                 json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *a):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.handle_request, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_port}/v1/metrics"
        self.assertTrue(probe.send(url, probe.otlp_payload([("x", "1", 1, {})], 1)))
        server.server_close()
        self.assertEqual(received[0][0], "/v1/metrics")
        self.assertEqual(received[0][1], "application/json")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(probe.send(url, probe.otlp_payload([], 1)))   # nobody listening now


if __name__ == "__main__":
    unittest.main()
