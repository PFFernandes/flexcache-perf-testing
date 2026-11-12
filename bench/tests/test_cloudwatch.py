"""Run: python3 -m unittest discover -s bench/tests -t ."""
import contextlib
import io
import json
import os
import tempfile
import time
import unittest

from bench.dataset.cli import main as dataset_main
from bench.results import cloudwatch as cw

T0 = int(time.time()) // 60 * 60 - 600   # a whole minute, ten minutes ago


def dp(ts, value, **attrs):
    return {"timeUnixNano": str(int(ts * 1e9)), "asDouble": value,
            "attributes": [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()]}


def line(metrics):
    return json.dumps({"resourceMetrics": [{"scopeMetrics": [{"metrics": metrics}]}]})


def telemetry_lines():
    lines = []
    for i in range(24):                                 # 2 minutes at 5 s
        t = T0 + 5 * i
        lines.append(line([
            {"name": "system.cpu.utilization", "gauge": {"dataPoints": [
                dp(t, 0.75, cpu="cpu0", state="idle"), dp(t, 0.25, cpu="cpu1", state="idle"),
                dp(t, 0.10, cpu="cpu0", state="user")]}},
            {"name": "system.network.io", "sum": {"dataPoints": [
                dp(t, 1000.0 * i, device="ens5", direction="receive"),
                dp(t, 99999.0 * i, device="lo", direction="receive")]}},
            {"name": "bench.nfs.rtt", "gauge": {"dataPoints": [
                dp(t, 2.0, mount="/mnt/fsxn/vol_origin", op="READ"),
                dp(t, 9.0, mount="/mnt/fsxn/vol_origin", op="NULL")]}},
            {"name": "bench.ping.rtt", "gauge": {"dataPoints": [dp(t, 0.4, target="origin-nfs")]}},
        ]))
    lines.append('{"resourceMetrics": [{"half written')   # the active file's last line
    return lines


class Mapping(unittest.TestCase):
    def series(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            fh.write("\n".join(telemetry_lines()) + "\n")
        try:
            return cw.series_from_telemetry(cw.read_otlp([fh.name]))
        finally:
            os.unlink(fh.name)

    def test_cpu_network_nfs(self):
        s = self.series()
        cpu = {v for m, _u, _d, _t, v in s if m == "CpuBusyPercent"}
        self.assertEqual(cpu, {50.0})                                          # 1 - mean(0.75, 0.25)
        net = [(d, v) for m, _u, d, _t, v in s if m == "NetworkBytesPerSecond"]
        self.assertTrue(net)
        self.assertTrue(all(d == (("Direction", "receive"),) and abs(v - 200.0) < 1e-6 for d, v in net))   # lo left out
        nfs = {d for m, _u, d, _t, _v in s if m == "NfsRttMs"}
        self.assertEqual(nfs, {(("Mount", "/mnt/fsxn/vol_origin"), ("Op", "READ"))})            # NULL left out
        self.assertIn("PingRttMs", {m for m, *_ in s})

    def test_per_minute_whole_past_minutes_only(self):
        s = self.series()
        groups = cw.per_minute(s, now=T0 + 90, cursor={})                      # minute T0+60 is still running
        minutes = {g[4] for g in groups}
        self.assertEqual(minutes, {T0})
        ping = next(g for g in groups if g[1] == "PingRttMs")
        self.assertEqual(ping[5]["SampleCount"], 12.0)
        self.assertAlmostEqual(ping[5]["Sum"], 4.8)
        groups = cw.per_minute(s, now=T0 + 150, cursor={g[0]: T0 for g in groups})
        self.assertEqual({g[4] for g in groups}, {T0 + 60})                    # cursor: T0 already sent
        self.assertEqual(cw.per_minute(s, now=T0 + 15 * 86400, cursor={}), [])  # too old for CloudWatch

    def test_values_counts_limit(self):
        vals, counts = cw.values_counts([1.0 + i * 0.001 for i in range(5000)])
        self.assertLessEqual(len(vals), cw.MAX_VALUES)
        self.assertEqual(sum(counts), 5000)


class Push(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.staging = os.path.join(t, "staging")
        self.cursor = os.path.join(t, "cursor.json")
        tel = os.path.join(self.staging, "telemetry", "lab", "origin", "i-1")
        os.makedirs(tel)
        with open(os.path.join(tel, "metrics.json"), "w") as fh:
            fh.write("\n".join(telemetry_lines()) + "\n")
        vol = os.path.join(t, "vol")
        os.mkdir(vol)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = dataset_main(["--out", os.path.join(self.staging, "datasets"), "create", "--target", vol,
                                 "--id", "ds1", "--files", "30", "--file-size", "4KiB", "--jobs", "1"])
        self.assertEqual(code, 0, buf.getvalue())
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def runner(self, fail=False):
        def run(cmd, **kw):
            with open(cmd[cmd.index("--cli-input-json") + 1][len("file://"):]) as fh:
                self.calls.append((cmd, json.load(fh)))

            class R:
                returncode = 1 if fail else 0
                stdout = ""
                stderr = "AccessDenied" if fail else ""
            return R()
        return run

    def push(self, now, fail=False):
        return cw.push(self.staging, lab="lab1", side="origin", region="eu-west-1",
                       cursor_path=self.cursor, now=now, runner=self.runner(fail))

    def test_push_once_then_only_new_minutes(self):
        now = time.time() + 61                                   # after the dataset's minute too
        counts = self.push(now)
        self.assertEqual(counts["datasets"], 1)
        cmd, body = self.calls[0]
        self.assertEqual(cmd[:3], ["aws", "cloudwatch", "put-metric-data"])
        self.assertEqual(body["Namespace"], "FlexCacheBench")
        names = {d["MetricName"] for d in body["MetricData"]}
        self.assertTrue({"CpuBusyPercent", "NfsRttMs", "DatasetBytesWritten", "DatasetOpenLatency"} <= names)
        dims = {(x["Name"], x["Value"]) for d in body["MetricData"] for x in d["Dimensions"]}
        self.assertTrue({("Lab", "lab1"), ("Side", "origin"), ("Dataset", "ds1")} <= dims)
        files = sum(d["StatisticValues"]["Sum"] for d in body["MetricData"]
                    if d["MetricName"] == "DatasetFilesWritten")
        self.assertEqual(files, 30)
        lat = [d for d in body["MetricData"] if d["MetricName"] == "DatasetOpenLatency"]
        self.assertEqual(sum(sum(d["Counts"]) for d in lat), 30)

        self.calls.clear()
        self.assertEqual(self.push(now)["datums"], 0)            # nothing new: nothing sent
        self.assertEqual(self.calls, [])

    def test_failed_push_is_retried(self):
        now = time.time() + 61
        with self.assertRaises(RuntimeError):
            self.push(now, fail=True)
        self.assertFalse(os.path.exists(self.cursor))
        self.calls.clear()
        self.assertGreater(self.push(now)["datums"], 0)          # the same data goes next time


if __name__ == "__main__":
    unittest.main()
