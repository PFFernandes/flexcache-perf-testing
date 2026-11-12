"""Run: python3 -m unittest discover -s bench/tests -t ."""
import contextlib
import csv
import glob
import gzip
import io
import json
import os
import tempfile
import time
import unittest

from bench.dataset.cli import main
from bench.results import cloudwatch as cw
from bench.results import sync


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = main(list(argv))
    return code, out.getvalue()


class Read(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.vol, self.out = os.path.join(t, "vol"), os.path.join(t, "out")
        os.mkdir(self.vol)
        code, text = run("--out", self.out, "create", "--target", self.vol, "--id", "ds1", "--files", "40",
                         "--file-size", "1KiB-3MiB", "--jobs", "2", "--block-size", "256KiB")
        self.assertEqual(code, 0, text)
        with open(os.path.join(self.out, "ds1", "dataset.json")) as fh:
            self.total = json.load(fh)["generations"][0]["bytes"]

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, *extra):
        return run("--out", self.out, "read", "ds1", "--side", "origin", "--target", self.vol, "--jobs", "2", *extra)

    def records(self):
        return sorted(glob.glob(os.path.join(self.out, "ds1", "reads", "read-*.json")))

    def rows(self, path):
        with gzip.open(path, "rt", newline="") as fh:
            return list(csv.DictReader(fh))

    def test_full_read_two_passes(self):
        code, text = self.read()
        self.assertEqual(code, 0, text)
        self.assertIn("pass 1/2", text)
        self.assertIn("pass 2/2", text)
        self.assertIn("first", text)
        self.assertIn("whole", text)
        recs = self.records()
        self.assertEqual(len(recs), 2)
        with open(recs[0]) as fh:
            r = json.load(fh)
        self.assertEqual((r["pass"], r["passes"], r["mode"], r["side"], r["files"]), (1, 2, "full", "origin", 40))
        self.assertEqual(r["bytes"], self.total)                          # every byte read
        self.assertIn("first_us", r["latency_us"]["read"])
        self.assertIn("io_us", r["latency_us"]["read"])
        self.assertGreater(r["wall_s"], 0)
        rows = self.rows(os.path.join(self.out, "ds1", r["ops"]))
        self.assertEqual(len(rows), 40)
        for row in rows:
            self.assertEqual(row["action"], "read")
            self.assertTrue(row["open_us"] != "" and row["first_us"] != "" and row["io_us"] != "" and row["close_us"] != "")
            self.assertLessEqual(int(row["first_us"]), int(row["io_us"]))   # first byte comes before the last

        # The dataset record itself is not changed by a read (both sides can read at once).
        with open(os.path.join(self.out, "ds1", "dataset.json")) as fh:
            self.assertNotIn("reads", json.load(fh))

    def test_modes_and_sample(self):
        self.assertEqual(self.read("--mode", "open", "--passes", "1", "--files", "10")[0], 0)
        with open(self.records()[-1]) as fh:
            r = json.load(fh)
        self.assertEqual((r["files"], r["bytes"], r["mode"]), (10, 0, "open"))       # no data in open mode
        rows = self.rows(os.path.join(self.out, "ds1", r["ops"]))
        self.assertTrue(all(row["first_us"] == "" and row["open_us"] != "" for row in rows))
        time.sleep(1.1)   # records are named by second
        self.assertEqual(self.read("--mode", "first", "--passes", "1", "--block-size", "64KiB")[0], 0)
        with open(self.records()[-1]) as fh:
            r = json.load(fh)
        self.assertLessEqual(r["bytes"], 40 * 64 * 1024)                              # one block per file
        self.assertGreater(r["bytes"], 0)

    def test_missing_file_is_an_error(self):
        victim = next(p for p in glob.glob(os.path.join(self.vol, "ds1", "**", "*.dat"), recursive=True))
        os.remove(victim)
        code, text = self.read("--passes", "1")
        self.assertEqual(code, 1)
        self.assertIn("ERROR", text)

    def test_reads_reach_the_volume_and_cloudwatch(self):
        self.assertEqual(self.read()[0], 0)
        results = os.path.join(self.tmp.name, "vol_bench")
        # Stage like the clients do: <staging>/datasets/<id>, then sync to the volume.
        staging = os.path.join(self.tmp.name, "staging")
        os.makedirs(os.path.join(staging, "datasets"))
        os.rename(os.path.join(self.out, "ds1"), os.path.join(staging, "datasets", "ds1"))
        calls = []

        def runner(cmd, **kw):
            with open(cmd[cmd.index("--cli-input-json") + 1][len("file://"):]) as fh:
                calls.append(json.load(fh))

            class R:
                returncode, stdout, stderr = 0, "", ""
            return R()
        cw.push(staging, lab="lab1", side="cache", region="us-east-1",
                cursor_path=os.path.join(self.tmp.name, "cursor.json"), now=time.time() + 61, runner=runner)
        data = [d for c in calls for d in c["MetricData"]]
        names = {d["MetricName"] for d in data}
        self.assertTrue({"DatasetBytesRead", "DatasetFilesRead", "DatasetReadOpenLatency", "DatasetFirstByteLatency",
                         "DatasetReadTime", "DatasetReadCloseLatency"} <= names)
        passes = {x["Value"] for d in data if d["MetricName"] == "DatasetBytesRead" for x in d["Dimensions"] if x["Name"] == "Pass"}
        self.assertEqual(passes, {"1", "2"})
        read_bytes = sum(d["StatisticValues"]["Sum"] for d in data if d["MetricName"] == "DatasetBytesRead")
        self.assertEqual(read_bytes, 2 * self.total)

        sync.sync(staging, results, log=lambda m: None)
        self.assertEqual(len(glob.glob(os.path.join(results, "datasets", "ds1", "reads", "read-*.json"))), 2)
        self.assertEqual(len(glob.glob(os.path.join(results, "datasets", "ds1", "reads", "ops-read-*.csv.gz"))), 2)


if __name__ == "__main__":
    unittest.main()
