"""Turn a normalized spec into a deterministic list of files: (index, relative path, size).

The same spec and seed always give the same names and sizes, on any machine.
"""
from __future__ import annotations

import math
import random


def _sizes(spec: dict, rng: random.Random) -> list:
    buckets, files, total = spec["buckets"], spec["files"], spec["total"]
    weights = [b["weight"] for b in buckets]

    def one() -> int:
        b = buckets[0] if len(buckets) == 1 else rng.choices(buckets, weights)[0]
        return b["lo"] if b["lo"] == b["hi"] else rng.randint(b["lo"], b["hi"])

    if files is not None:
        return [one() for _ in range(files)]
    # Only the total is fixed: add files until it is reached, then trim the last one to fit.
    sizes, used = [], 0
    while used < total:
        size = min(one(), total - used)
        sizes.append(size)
        used += size
    return sizes


def _fanout(n_dirs: int, depth: int) -> int:
    fan = max(1, round(n_dirs ** (1.0 / depth)))
    while fan ** depth < n_dirs:
        fan += 1
    return fan


def rel_path(position: int, n_files: int, files_per_dir: int, depth: int, index: int) -> str:
    """Path of the file at `position` (0-based) in a tree holding n_files; named after `index`."""
    name = f"f{index:08d}.dat"
    if depth == 0:
        return name
    n_dirs = math.ceil(n_files / files_per_dir)
    fan = _fanout(n_dirs, depth)
    d, parts = position // files_per_dir, []
    for _ in range(depth):
        parts.append(f"d{d % fan:04d}")
        d //= fan
    return "/".join(reversed(parts)) + "/" + name


def plan(spec: dict, gen: int = 0, first_index: int = 0, prefix: str = "") -> list:
    """Return [{'idx', 'path', 'size'}] for generation `gen` of the dataset."""
    rng = random.Random(f"{spec['seed']}/plan/{gen}")
    sizes = _sizes(spec, rng)
    lay = spec["layout"]
    return [
        {"idx": first_index + i,
         "path": prefix + rel_path(i, len(sizes), lay["files_per_dir"], lay["depth"], first_index + i),
         "size": size}
        for i, size in enumerate(sizes)
    ]


def directories(entries: list) -> list:
    """Every directory the entries need, parents first."""
    dirs = set()
    for e in entries:
        parts = e["path"].split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    return sorted(dirs)
