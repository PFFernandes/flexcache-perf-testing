"""Does the file work, in parallel processes, and times every step of every file.

One task = one file and one action:

    create     open(O_CREAT|O_EXCL) -> write -> [fsync] -> close
    overwrite  open(O_WRONLY)       -> write at an offset -> [fsync] -> close
    append     open(O_APPEND)       -> write -> [fsync] -> close
    rename / chmod / delete         one metadata call
    verify     stat, and for files with a checksum: open -> read all -> close

Each task returns one row with the time of open, I/O, fsync and close in microseconds.
File contents come from the dataset seed, the generation and the file index, so the
same spec always writes the same bytes.
"""
from __future__ import annotations

import hashlib
import multiprocessing
import os
import random
import time

CHUNK = 64          # tasks handed to a process at a time
READ_SIZE = 1 << 20

_cfg: dict = {}


def _init(cfg: dict) -> None:
    global _cfg
    _cfg = cfg
    rng = random.Random(f"{cfg['seed']}/dedupe")
    _cfg["dedupe_block"] = rng.randbytes(cfg["block_size"])


def _blocks(rng: random.Random, length: int):
    """Yield `length` bytes of data in blocks, honoring compress_percent / dedupe_percent."""
    bs, compress, dedupe = _cfg["block_size"], _cfg["compress_percent"], _cfg["dedupe_percent"]
    while length > 0:
        n = min(bs, length)
        if dedupe and rng.random() * 100 < dedupe:
            yield _cfg["dedupe_block"][:n]
        else:
            keep = n if not compress else n * (100 - compress) // 100
            yield rng.randbytes(keep) + bytes(n - keep)
        length -= n


def _us(start_ns: int) -> int:
    return (time.perf_counter_ns() - start_ns) // 1000


def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as fh:
        while True:
            chunk = fh.read(READ_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _write(task: dict, path: str, row: dict) -> None:
    action = task["action"]
    flags = {
        "create": os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        "overwrite": os.O_WRONLY,
        "append": os.O_WRONLY | os.O_APPEND,
    }[action]
    length = task["size"] if action == "create" else task["length"]
    rng = random.Random(f"{_cfg['seed']}/data/{_cfg['gen']}/{task['idx']}")
    digest = hashlib.sha256() if action == "create" and task.get("want_sum") else None

    t = time.perf_counter_ns()
    try:
        fd = os.open(path, flags, 0o644)
    except FileExistsError:
        if _cfg.get("resume") and os.stat(path).st_size == task["size"]:
            row["action"] = "skip"
            if task.get("want_sum"):
                row["sha256"] = _sha256(path)
            return
        raise
    row["open_us"] = _us(t)
    try:
        if action == "overwrite":
            os.lseek(fd, task["offset"], os.SEEK_SET)
        t = time.perf_counter_ns()
        for block in _blocks(rng, length):
            view = memoryview(block)
            while view:
                view = view[os.write(fd, view):]
            if digest:
                digest.update(block)
        row["io_us"] = _us(t)
        row["bytes"] = length
        if _cfg["fsync"]:
            t = time.perf_counter_ns()
            os.fsync(fd)
            row["fsync_us"] = _us(t)
    finally:
        t = time.perf_counter_ns()
        os.close(fd)
        row["close_us"] = _us(t)
    if digest:
        row["sha256"] = digest.hexdigest()
    elif task.get("want_sum"):
        row["sha256"] = _sha256(path)   # modified file: checksum of the new content


def _verify(task: dict, path: str, row: dict) -> None:
    t = time.perf_counter_ns()
    size = os.stat(path).st_size
    row["io_us"] = _us(t)
    if size != task["size"]:
        row["error"] = f"size {size} != {task['size']}"
        return
    if not task.get("sha256"):
        return
    digest = hashlib.sha256()
    t = time.perf_counter_ns()
    fd = os.open(path, os.O_RDONLY)
    row["open_us"] = _us(t)
    try:
        t = time.perf_counter_ns()
        while True:
            chunk = os.read(fd, READ_SIZE)
            if not chunk:
                break
            digest.update(chunk)
        row["io_us"] = _us(t)
        row["bytes"] = size
    finally:
        t = time.perf_counter_ns()
        os.close(fd)
        row["close_us"] = _us(t)
    if digest.hexdigest() != task["sha256"]:
        row["error"] = "checksum mismatch"


def _one(task: dict) -> dict:
    path = os.path.join(_cfg["root"], task["path"])
    row = {"ts": time.time(), "idx": task["idx"], "action": task["action"], "open_us": "", "io_us": "",
           "fsync_us": "", "close_us": "", "bytes": 0, "error": "", "sha256": ""}
    try:
        action = task["action"]
        if action in ("create", "overwrite", "append"):
            _write(task, path, row)
        elif action == "verify":
            _verify(task, path, row)
        else:
            t = time.perf_counter_ns()
            if action == "rename":
                os.rename(path, os.path.join(_cfg["root"], task["new_path"]))
            elif action == "chmod":
                os.chmod(path, 0o640)
            elif action == "delete":
                os.unlink(path)
            else:
                raise ValueError(f"unknown action {action}")
            row["io_us"] = _us(t)
    except OSError as exc:
        row["error"] = f"{type(exc).__name__}: {exc.strerror or exc}"
    return row


def _chunk(tasks: list) -> list:
    return [_one(task) for task in tasks]


def run(root: str, tasks: list, spec: dict, gen: int, jobs: int, resume: bool = False):
    """Run the tasks and yield one result row per task (in completion order)."""
    cfg = {
        "root": root, "seed": spec["seed"], "gen": gen, "resume": resume,
        "block_size": spec["writers"]["block_size"], "fsync": spec["writers"]["fsync"],
        "compress_percent": spec["data"]["compress_percent"],
        "dedupe_percent": spec["data"]["dedupe_percent"],
    }
    chunks = [tasks[i:i + CHUNK] for i in range(0, len(tasks), CHUNK)]
    if jobs == 1 or len(chunks) <= 1:
        _init(cfg)
        for chunk in chunks:
            yield from _chunk(chunk)
        return
    with multiprocessing.Pool(min(jobs, len(chunks)), _init, (cfg,)) as pool:
        for rows in pool.imap_unordered(_chunk, chunks):
            yield from rows
