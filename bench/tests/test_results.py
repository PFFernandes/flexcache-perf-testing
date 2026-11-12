"""Run: python3 -m unittest discover -s bench/tests -t ."""
import contextlib
import fcntl
import io
import os
import tempfile
import unittest

from bench.dataset.cli import default_out, main
from bench.results import sync


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = main(list(argv))
    return code, out.getvalue()


class Env:
    """Set environment variables for a test and restore them afterwards."""

    def __init__(self, **values):
        self.values = values

    def __enter__(self):
        self.old = {k: os.environ.get(k) for k in ("BENCH_OUT", "BENCH_STAGING", "BENCH_RESULTS_DIR")}
        for k in self.old:
            os.environ.pop(k, None)
        os.environ.update({k: v for k, v in self.values.items() if v is not None})

    def __exit__(self, *exc):
        for k, v in self.old.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


class StagingThenSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.vol, self.staging, self.results = (os.path.join(t, d) for d in ("vol_origin", "staging", "vol_bench"))
        for d in (self.vol, self.staging, os.path.join(self.results, "datasets")):
            os.makedirs(d)

    def tearDown(self):
        self.tmp.cleanup()

    def env(self):
        return Env(BENCH_STAGING=self.staging, BENCH_RESULTS_DIR=self.results)

    def create(self, ds="ds1"):
        return run("create", "--target", self.vol, "--id", ds, "--files", "20", "--file-size", "1KiB",
                   "--jobs", "1", "--checksums", "all")

    def test_default_out(self):
        with Env():
            self.assertEqual(default_out(), "results/datasets")
        with Env(BENCH_STAGING="/var/lib/bench/staging", BENCH_RESULTS_DIR="/mnt/fsxn/vol_bench"):
            self.assertEqual(default_out(), "/var/lib/bench/staging/datasets")   # never the volume
        with Env(BENCH_OUT="/elsewhere", BENCH_STAGING="/s"):
            self.assertEqual(default_out(), "/elsewhere")

    def test_command_writes_only_to_staging(self):
        with self.env():
            self.assertEqual(self.create()[0], 0)
        self.assertTrue(os.path.exists(os.path.join(self.staging, "datasets", "ds1", "dataset.json")))
        self.assertEqual(os.listdir(os.path.join(self.results, "datasets")), [])     # nothing on the volume yet

    def test_sync_moves_records_and_later_commands_read_them_back(self):
        with self.env():
            self.create()
        counts = sync.sync(self.staging, self.results, log=lambda m: None)
        self.assertEqual(counts["datasets"], 1)
        self.assertTrue(os.path.exists(os.path.join(self.results, "datasets", "ds1", "manifest-g0.csv.gz")))
        self.assertFalse(os.path.exists(os.path.join(self.results, "datasets", "ds1", ".lock")))
        self.assertFalse(os.path.exists(os.path.join(self.staging, "datasets", "ds1")))   # moved, not copied

        with self.env():
            code, text = run("list")
            self.assertIn("[vol_bench]", text)
            code, text = run("verify", "ds1", "--side", "origin")      # reads the records back first
            self.assertEqual(code, 0, text)
            code, text = run("list")
            self.assertIn("[staged]", text)                            # the verify is staged, not yet copied
            self.assertEqual(self.create()[0], 2)                      # id already exists on the volume
        sync.sync(self.staging, self.results, log=lambda m: None)
        import json
        with open(os.path.join(self.results, "datasets", "ds1", "dataset.json")) as fh:
            self.assertEqual(len(json.load(fh)["verifications"]), 1)

    def test_sync_skips_a_dataset_in_use(self):
        with self.env():
            self.create()
        lock = open(os.path.join(self.staging, "datasets", "ds1", ".lock"), "a")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)               # as a running command would
        try:
            counts = sync.sync(self.staging, self.results, log=lambda m: None)
        finally:
            lock.close()
        self.assertEqual((counts["datasets"], counts["datasets_busy"]), (0, 1))
        self.assertTrue(os.path.exists(os.path.join(self.staging, "datasets", "ds1")))
        self.assertEqual(sync.sync(self.staging, self.results, log=lambda m: None)["datasets"], 1)

    def test_telemetry_rotated_files_move_active_file_stays(self):
        tel = os.path.join(self.staging, "telemetry", "lab", "origin", "i-1")
        os.makedirs(tel)
        for name, body in (("metrics.json", "active\n"), ("metrics-2026-11-12T10-00-00.000.json", "old\n")):
            with open(os.path.join(tel, name), "w") as fh:
                fh.write(body)
        logs = os.path.join(self.staging, "logs")
        os.makedirs(logs)
        with open(os.path.join(logs, "run.log"), "w") as fh:
            fh.write("log\n")

        counts = sync.sync(self.staging, self.results, log=lambda m: None)
        dest = os.path.join(self.results, "telemetry", "lab", "origin", "i-1")
        self.assertEqual(sorted(os.listdir(dest)), ["metrics-2026-11-12T10-00-00.000.json", "metrics.json"])
        self.assertEqual(os.listdir(tel), ["metrics.json"])                 # rotated file removed locally
        self.assertTrue(os.path.exists(os.path.join(logs, "run.log")))      # logs kept locally
        self.assertEqual((counts["telemetry"], counts["telemetry_removed"], counts["logs"]), (2, 1, 1))

        with open(os.path.join(tel, "metrics.json"), "a") as fh:            # the collector keeps writing
            fh.write("more\n")
        sync.sync(self.staging, self.results, log=lambda m: None)
        with open(os.path.join(dest, "metrics.json")) as fh:
            self.assertEqual(fh.read(), "active\nmore\n")
        self.assertEqual(sync.sync(self.staging, self.results, log=lambda m: None)["telemetry"], 0)  # unchanged: no copy

    def test_cli_needs_a_mounted_results_volume(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            self.assertEqual(sync.main(["--staging", self.staging, "--results", self.results]), 1)  # not a mount point
            self.assertEqual(sync.main(["--staging", self.staging, "--results", ""]), 0)
        self.assertIn("is not mounted", out.getvalue())


if __name__ == "__main__":
    unittest.main()
