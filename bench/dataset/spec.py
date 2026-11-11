"""Dataset specs: load them (YAML or JSON), build them from CLI flags, and normalize them.

A normalized spec is a plain dict:

    name, seed
    files        int or None      } any two of files / total / buckets
    total        bytes or None    }
    buckets      list of {weight, lo, hi} (bytes) or None
    layout       {files_per_dir, depth}
    data         {compress_percent, dedupe_percent}
    writers      {side, jobs, block_size, checksums, fsync}
"""
from __future__ import annotations

import json
import os

from .sizes import parse_size

DEFAULTS = {
    "seed": 42,
    "layout": {"files_per_dir": 1000, "depth": 2},
    "data": {"compress_percent": 0, "dedupe_percent": 0},
    "writers": {"side": "origin", "jobs": 8, "block_size": "1MiB", "checksums": "sample", "fsync": False},
}
CHECKSUM_MODES = ("none", "sample", "all")
SIDES = ("origin", "cache")


class SpecError(ValueError):
    pass


def find_spec(name: str) -> str:
    """A spec path as given, or a profile name: 'smoke' -> profiles/datasets/smoke.json.

    Looks in the current folder, then in $BENCH_HOME (set by the bench-dataset command
    on the clients), trying the name as a path and under profiles/datasets/ with
    .json, .yaml and .yml.
    """
    roots = [os.getcwd()]
    if os.environ.get("BENCH_HOME"):
        roots.append(os.environ["BENCH_HOME"])
    tried = []
    for root in roots:
        for rel in (name, os.path.join("profiles", "datasets", name)):
            for ext in ("", ".json", ".yaml", ".yml"):
                path = os.path.join(root, rel + ext)
                tried.append(path)
                if os.path.isfile(path):
                    return path
    raise SpecError(f"spec {name!r} not found (looked for {', '.join(tried[:4])}, ...)")


def load_file(path: str) -> dict:
    """Read a spec file. JSON always works; YAML needs PyYAML."""
    with open(path) as fh:
        text = fh.read()
    if path.endswith(".json"):
        return json.loads(text)
    try:
        import yaml  # type: ignore
    except ImportError:
        raise SpecError(f"{path}: reading YAML needs PyYAML (pip install pyyaml), or use a .json spec")
    return yaml.safe_load(text)


def _bucket(value, weight=1.0) -> dict:
    """One file-size entry: '64KiB', '1MiB-64MiB', {fixed: ..}, {range: [a, b]}."""
    if isinstance(value, dict):
        weight = float(value.get("weight", weight))
        if "fixed" in value:
            lo = hi = parse_size(value["fixed"])
        elif "range" in value:
            lo, hi = (parse_size(v) for v in value["range"])
        else:
            raise SpecError(f"file size entry needs 'fixed' or 'range': {value!r}")
    else:
        text = str(value)
        if "-" in text:
            lo, hi = (parse_size(v) for v in text.split("-", 1))
        else:
            lo = hi = parse_size(value)
    if lo > hi:
        raise SpecError(f"file size range is backwards: {value!r}")
    if hi < 1:
        raise SpecError(f"file size must be at least 1 byte: {value!r}")
    if weight <= 0:
        raise SpecError(f"weight must be positive: {value!r}")
    return {"weight": weight, "lo": max(lo, 1), "hi": hi}


def parse_file_size(value) -> list:
    """file_size from a spec or --file-size: scalar, 'a-b', {fixed}, {range}, {mix: [...]}."""
    if isinstance(value, dict) and "mix" in value:
        if not value["mix"]:
            raise SpecError("file_size.mix is empty")
        return [_bucket(entry) for entry in value["mix"]]
    return [_bucket(value)]


def parse_size_mix(text: str) -> list:
    """--size-mix '70:4KiB-64KiB,25:1MiB-16MiB,5:1GiB' (weight:size)."""
    buckets = []
    for part in text.split(","):
        if ":" not in part:
            raise SpecError(f"--size-mix entries are weight:size, got {part!r}")
        weight, size = part.split(":", 1)
        buckets.append(_bucket(size.strip(), float(weight)))
    return buckets


def mean_size(buckets: list) -> float:
    total_weight = sum(b["weight"] for b in buckets)
    return sum(b["weight"] * (b["lo"] + b["hi"]) / 2 for b in buckets) / total_weight


def normalize(raw: dict) -> dict:
    """Validate a raw spec (from a file or from flags) and fill in the defaults."""
    if not isinstance(raw, dict):
        raise SpecError("a spec must be a mapping")
    size = raw.get("size") or {}
    files = size.get("files")
    total = parse_size(size["total"]) if size.get("total") is not None else None
    buckets = parse_file_size(size["file_size"]) if size.get("file_size") is not None else None

    given = sum(x is not None for x in (files, total, buckets))
    if given < 2:
        raise SpecError("give any two of: number of files, file size, total size")
    if files is not None and (not isinstance(files, int) or files < 1):
        raise SpecError(f"files must be a positive whole number, got {files!r}")
    if total is not None and total < 1:
        raise SpecError("total must be at least 1 byte")
    if buckets is None:
        if total < files:
            raise SpecError("total is smaller than one byte per file")
        buckets = [{"weight": 1.0, "lo": total // files, "hi": total // files}]
    elif files is not None and total is not None:
        expected = files * mean_size(buckets)
        if abs(expected - total) > 0.01 * total:
            raise SpecError(
                f"files x file size = {expected:.0f} bytes, but total = {total} bytes (more than 1% apart). "
                "Give only two of the three."
            )

    spec = {
        "name": str(raw.get("name") or "dataset"),
        "seed": raw.get("seed", DEFAULTS["seed"]),
        "files": files,
        "total": total,
        "buckets": buckets,
    }
    for section in ("layout", "data", "writers"):
        merged = dict(DEFAULTS[section])
        extra = raw.get(section) or {}
        unknown = set(extra) - set(merged)
        if unknown:
            raise SpecError(f"unknown {section} setting(s): {', '.join(sorted(unknown))}")
        merged.update(extra)
        spec[section] = merged

    lay, data, wr = spec["layout"], spec["data"], spec["writers"]
    if lay["files_per_dir"] < 1 or lay["depth"] < 0:
        raise SpecError("layout: files_per_dir must be >= 1 and depth >= 0")
    for key in ("compress_percent", "dedupe_percent"):
        if not 0 <= data[key] <= 100:
            raise SpecError(f"data.{key} must be between 0 and 100")
    wr["block_size"] = parse_size(wr["block_size"])
    if wr["block_size"] < 4096:
        raise SpecError("writers.block_size must be at least 4KiB")
    if wr["jobs"] < 1:
        raise SpecError("writers.jobs must be >= 1")
    if wr["checksums"] not in CHECKSUM_MODES:
        raise SpecError(f"writers.checksums must be one of {CHECKSUM_MODES}")
    if wr["side"] not in SIDES:
        raise SpecError(f"writers.side must be one of {SIDES}")
    if not all(c.isalnum() or c in "-_." for c in spec["name"]):
        raise SpecError("name may only contain letters, digits, '-', '_' and '.'")
    return spec


def from_args(args) -> dict:
    """Build the raw spec from --spec and/or the sizing flags (flags win over the file)."""
    raw = load_file(find_spec(args.spec)) if getattr(args, "spec", None) else {}
    raw = json.loads(json.dumps(raw))  # deep copy
    size = raw.setdefault("size", {})
    if getattr(args, "spec", None) and not raw.get("name"):
        raw["name"] = os.path.splitext(os.path.basename(args.spec))[0]
    if getattr(args, "name", None):
        raw["name"] = args.name
    if getattr(args, "files", None) is not None:
        size["files"] = args.files
    if getattr(args, "total", None):
        size["total"] = args.total
    if getattr(args, "file_size", None) and getattr(args, "size_mix", None):
        raise SpecError("use --file-size or --size-mix, not both")
    if getattr(args, "file_size", None):
        size["file_size"] = args.file_size
    if getattr(args, "size_mix", None):
        size["file_size"] = {"mix": [
            {"weight": b["weight"], "range": [b["lo"], b["hi"]]} for b in parse_size_mix(args.size_mix)
        ]}
    for section, key, attr in (
        ("writers", "jobs", "jobs"), ("writers", "side", "side"), ("writers", "checksums", "checksums"),
        ("writers", "block_size", "block_size"), ("layout", "files_per_dir", "files_per_dir"),
        ("layout", "depth", "depth"), ("data", "compress_percent", "compress_percent"),
        ("data", "dedupe_percent", "dedupe_percent"),
    ):
        value = getattr(args, attr, None)
        if value is not None:
            raw.setdefault(section, {})[key] = value
    if getattr(args, "fsync", False):
        raw.setdefault("writers", {})["fsync"] = True
    if getattr(args, "seed", None) is not None:
        raw["seed"] = args.seed
    return raw
