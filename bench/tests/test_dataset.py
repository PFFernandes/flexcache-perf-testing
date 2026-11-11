"""Run: python3 -m unittest discover -s bench/tests -t ."""
import contextlib
import io
import os
import tempfile
import unittest

from bench.dataset import planner, spec as specmod
from bench.dataset.cli import main
from bench.dataset.sizes import parse_size
from bench.dataset.store import Store, percentile


def norm(**size):
    return specmod.normalize({"name": "t", "size": size})


class Sizes(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(parse_size("64KiB"), 65536)
        self.assertEqual(parse_size("1.5GiB"), 1610612736)
        self.assertEqual(parse_size("500GB"), 500 * 1000**3)
        self.assertEqual(parse_size(4096), 4096)
        for bad in ("abc", "10XB", "-1", True):
            with self.assertRaises(ValueError):
                parse_size(bad)

    def test_percentile(self):
        values = list(range(1, 101))
        self.assertEqual(percentile(values, 50), 50)
        self.assertEqual(percentile(values, 99), 99)
        self.assertEqual(percentile(values, 99.9), 100)
        self.assertEqual(percentile([], 50), 0)


class Sizing(unittest.TestCase):
    def test_files_and_size(self):
        entries = planner.plan(norm(files=100, file_size="64KiB"))
        self.assertEqual(len(entries), 100)
        self.assertEqual(sum(e["size"] for e in entries), 100 * 65536)

    def test_total_and_size_derives_files(self):
        entries = planner.plan(norm(total="2GiB", file_size="1MiB"))
        self.assertEqual(len(entries), 2048)

    def test_total_and_files_derives_size(self):
        entries = planner.plan(norm(total="1GiB", files=4))
        self.assertEqual({e["size"] for e in entries}, {2**28})

    def test_total_with_range_hits_total_exactly(self):
        total = parse_size("300MiB")
        entries = planner.plan(norm(total=total, file_size="1MiB-8MiB"))
        self.assertEqual(sum(e["size"] for e in entries), total)
        self.assertTrue(all(1 <= e["size"] <= 8 * 2**20 for e in entries))

    def test_mix_weights_are_file_shares(self):
        spec = norm(files=10000, file_size={"mix": [{"weight": 70, "range": ["4KiB", "64KiB"]},
                                                    {"weight": 30, "fixed": "1MiB"}]})
        entries = planner.plan(spec)
        big = sum(1 for e in entries if e["size"] == 2**20)
        self.assertAlmostEqual(big / 10000, 0.30, delta=0.02)

    def test_needs_two_of_three(self):
        for size in ({"files": 10}, {"total": "1GiB"}, {"file_size": "1MiB"}, {}):
            with self.assertRaises(specmod.SpecError):
                norm(**size)

    def test_all_three_must_agree(self):
        norm(files=1024, file_size="1MiB", total="1GiB")
        with self.assertRaises(specmod.SpecError):
            norm(files=1000, file_size="1MiB", total="2GiB")

    def test_rejects_bad_values(self):
        for raw in ({"size": {"files": 0, "file_size": "1MiB"}},
                    {"size": {"files": 1, "file_size": "8MiB-1MiB"}},
                    {"size": {"files": 1, "file_size": "1MiB"}, "data": {"compress_percent": 150}},
                    {"size": {"files": 1, "file_size": "1MiB"}, "writers": {"bogus": 1}},
                    {"size": {"files": 1, "file_size": "1MiB"}, "name": "a/b"}):
            with self.assertRaises(specmod.SpecError):
                specmod.normalize(raw)


class Planning(unittest.TestCase):
    def test_same_seed_same_plan(self):
        raw = {"name": "t", "seed": 7, "size": {"files": 500, "file_size": "1KiB-1MiB"}}
        a, b = planner.plan(specmod.normalize(raw)), planner.plan(specmod.normalize(raw))
        self.assertEqual(a, b)
        c = planner.plan(specmod.normalize({**raw, "seed": 8}))
        self.assertNotEqual([e["size"] for e in a], [e["size"] for e in c])

    def test_layout(self):
        spec = specmod.normalize({"size": {"files": 2500, "file_size": "1KiB"},
                                  "layout": {"files_per_dir": 100, "depth": 2}})
        entries = planner.plan(spec)
        self.assertEqual(len({e["path"] for e in entries}), 2500)
        per_dir = {}
        for e in entries:
            self.assertEqual(e["path"].count("/"), 2)
            per_dir[os.path.dirname(e["path"])] = per_dir.get(os.path.dirname(e["path"]), 0) + 1
        self.assertEqual(len(per_dir), 25)
        self.assertEqual(max(per_dir.values()), 100)

    def test_flat_layout(self):
        spec = specmod.normalize({"size": {"files": 10, "file_size": "1KiB"}, "layout": {"depth": 0}})
        self.assertTrue(all("/" not in e["path"] for e in planner.plan(spec)))


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = main(list(argv))
    return code, out.getvalue()


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.origin = os.path.join(self.tmp.name, "vol")
        self.out = os.path.join(self.tmp.name, "out")
        os.mkdir(self.origin)

    def tearDown(self):
        self.tmp.cleanup()

    def create(self, *extra, ds="ds1"):
        return run("--out", self.out, "create", "--target", self.origin, "--id", ds, "--files", "120",
                   "--file-size", "1KiB-64KiB", "--files-per-dir", "25", "--depth", "1",
                   "--checksums", "all", "--jobs", "3", *extra)

    def manifest(self, gen, ds="ds1"):
        return Store(self.out, ds).read_manifest(gen)

    def test_create_verify_delete(self):
        code, text = self.create()
        self.assertEqual(code, 0, text)
        entries = self.manifest(0)
        self.assertEqual(len(entries), 120)
        for e in entries:
            self.assertEqual(os.path.getsize(os.path.join(self.origin, "ds1", e["path"])), e["size"])
            self.assertEqual(len(e["sha256"]), 64)
        meta = Store(self.out, "ds1").load()
        g0 = meta["generations"][0]
        self.assertEqual(g0["operations"], {"create": 120})
        self.assertEqual(g0["bytes"], sum(e["size"] for e in entries))
        self.assertIn("open_us", g0["latency_us"]["create"])
        self.assertIn("close_us", g0["latency_us"]["create"])

        self.assertEqual(run("--out", self.out, "verify", "ds1", "--side", "origin")[0], 0)
        self.assertEqual(self.create()[0], 2)                       # same id again is refused
        self.assertEqual(run("--out", self.out, "delete", "ds1")[0], 2)   # needs --yes
        self.assertEqual(run("--out", self.out, "delete", "ds1", "--yes")[0], 0)
        self.assertFalse(os.path.exists(os.path.join(self.origin, "ds1")))
        self.assertTrue(Store(self.out, "ds1").load()["deleted"])

    def test_same_spec_writes_same_bytes(self):
        self.create(ds="a")
        self.create(ds="b")
        self.assertEqual([e["sha256"] for e in self.manifest(0, "a")],
                         [e["sha256"] for e in self.manifest(0, "b")])

    def test_verify_catches_corruption(self):
        self.create()
        victim = self.manifest(0)[5]
        with open(os.path.join(self.origin, "ds1", victim["path"]), "r+b") as fh:
            fh.write(b"\x00\x01corrupt")
        code, text = run("--out", self.out, "verify", "ds1", "--side", "origin")
        self.assertEqual(code, 1)
        self.assertIn("checksum mismatch", text)

    def test_modify_generations(self):
        self.create()
        before = {e["idx"]: e for e in self.manifest(0)}
        base = ("--out", self.out, "modify", "ds1", "--side", "cache")

        self.assertEqual(run(*base, "--mode", "overwrite", "--percent", "10", "--bytes", "4KiB")[0], 0)
        g1 = {e["idx"]: e for e in self.manifest(1)}
        changed = [i for i in g1 if g1[i]["sha256"] != before[i]["sha256"]]
        self.assertEqual(len(changed), 12)
        self.assertTrue(all(g1[i]["size"] == before[i]["size"] for i in g1))

        self.assertEqual(run(*base, "--mode", "append", "--percent", "5", "--bytes", "1KiB")[0], 0)
        g2 = {e["idx"]: e for e in self.manifest(2)}
        grown = [i for i in g2 if g2[i]["size"] == g1[i]["size"] + 1024]
        self.assertEqual(len(grown), 6)

        self.assertEqual(run(*base, "--mode", "metadata", "--percent", "10")[0], 0)
        g3 = {e["idx"]: e for e in self.manifest(3)}
        self.assertEqual(sum(1 for e in g3.values() if e["state"] == "deleted"), 4)
        self.assertEqual(sum(1 for e in g3.values() if e["path"].endswith(".g3")), 4)

        self.assertEqual(run(*base, "--mode", "create", "--files", "20", "--file-size", "2KiB")[0], 0)
        g4 = self.manifest(4)
        new = [e for e in g4 if e["path"].startswith("_gen4/")]
        self.assertEqual(len(new), 20)
        self.assertEqual(min(e["idx"] for e in new), 120)

        meta = Store(self.out, "ds1").load()
        self.assertEqual([g["side"] for g in meta["generations"]], ["origin"] + ["cache"] * 4)
        self.assertEqual(run("--out", self.out, "verify", "ds1", "--side", "origin")[0], 0)

    def test_resume_and_space_check(self):
        self.create()
        os.remove(os.path.join(self.origin, "ds1", self.manifest(0)[3]["path"]))
        code, text = self.create("--resume")
        self.assertEqual(code, 0, text)
        ops = Store(self.out, "ds1").load()["generations"][0]["operations"]
        self.assertEqual(ops, {"skip": 119, "create": 1})
        code, text = run("--out", self.out, "create", "--target", self.origin, "--total", "900TiB",
                         "--file-size", "1TiB")
        self.assertEqual(code, 2)
        self.assertIn("not enough free space", text)

    def test_spec_file_and_plan(self):
        here = os.path.dirname(__file__)
        smoke = os.path.join(here, "..", "..", "profiles", "datasets", "smoke.json")
        code, text = run("plan", "--spec", smoke)
        self.assertEqual(code, 0, text)
        self.assertIn("files      200", text)
        self.assertEqual(os.listdir(self.origin), [])


if __name__ == "__main__":
    unittest.main()
