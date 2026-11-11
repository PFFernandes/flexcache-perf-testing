"""bench dataset: plan | create | modify | verify | delete | list.

Runs on the machine that has the volume mounted (the origin or the cache client).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import platform
import random
import shutil
import socket
import sys
import time

from . import engine, planner, spec as specmod
from .sizes import format_size, parse_size
from .store import Recorder, Store, mount_of

MARKER = ".bench-dataset.json"
SPACE_MARGIN = 1.10
MODES = ("create", "overwrite", "append", "metadata")
META_OPS = ("rename", "chmod", "delete")


class Fail(Exception):
    pass


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _want_sum(mode: str, idx: int) -> bool:
    return mode == "all" or (mode == "sample" and idx % 100 == 0)


def _describe(spec: dict, entries: list) -> None:
    total = sum(e["size"] for e in entries)
    sizes = [e["size"] for e in entries]
    dirs = {os.path.dirname(e["path"]) for e in entries}
    print(f"dataset    {spec['name']}  (seed {spec['seed']})")
    print(f"files      {len(entries)}")
    print(f"total      {format_size(total)}  ({total} bytes)")
    print(f"file size  min {format_size(min(sizes))}, mean {format_size(total / len(sizes))}, "
          f"max {format_size(max(sizes))}")
    print(f"layout     {len(dirs)} directories, up to {spec['layout']['files_per_dir']} files each, "
          f"depth {spec['layout']['depth']}")
    print(f"data       compress {spec['data']['compress_percent']}%, dedupe {spec['data']['dedupe_percent']}%")
    wr = spec["writers"]
    print(f"writers    side {wr['side']}, {wr['jobs']} jobs, block {format_size(wr['block_size'])}, "
          f"checksums {wr['checksums']}, fsync {'on' if wr['fsync'] else 'off'}")


def _check_space(target: str, need: int, force: bool) -> None:
    st = os.statvfs(target)
    free = st.f_bavail * st.f_frsize
    print(f"free space {format_size(free)} on {target}; needs {format_size(need)} "
          f"(+{round((SPACE_MARGIN - 1) * 100)}% margin)")
    if need * SPACE_MARGIN > free:
        if not force:
            raise Fail("not enough free space (use --force to try anyway)")
        print("WARNING: not enough free space, continuing because of --force")


def _where(target: str, side: str) -> dict:
    return {"side": side, "target": os.path.abspath(target), "mount": mount_of(target),
            "host": socket.gethostname(), "kernel": platform.release()}


def _run_pass(store: Store, ops_name: str, root: str, tasks: list, spec: dict, gen: int, jobs: int,
              resume: bool = False):
    rec = Recorder(store.path(ops_name), len(tasks))
    for row in engine.run(root, tasks, spec, gen, jobs, resume):
        rec.add(row)
    return rec, rec.close()


def _print_summary(summary: dict, errors: list) -> None:
    print(f"done in {summary['wall_s']} s: {format_size(summary['bytes'])}, "
          f"{summary['throughput_bytes_per_s'] / 1e6:.1f} MB/s, {summary['files_per_s']} files/s")
    for action, fields in summary["latency_us"].items():
        for field in ("open_us", "io_us", "fsync_us", "close_us"):
            if field in fields:
                f = fields[field]
                print(f"  {action:9s} {field[:-3]:5s}  p50 {f['p50']:>9} us   p99 {f['p99']:>9} us   "
                      f"max {f['max']:>9} us   ({f['count']} ops)")
    if errors:
        print(f"{len(errors)} ERROR(S), first ones:")
        for idx, action, msg in errors[:10]:
            print(f"  file {idx} {action}: {msg}")


def _mkdirs(root: str, entries: list) -> float:
    start = time.perf_counter()
    for d in planner.directories(entries):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    return round(time.perf_counter() - start, 3)


# ---------------------------------------------------------------- plan / create

def cmd_plan(args) -> int:
    spec = specmod.normalize(specmod.from_args(args))
    entries = planner.plan(spec)
    _describe(spec, entries)
    if args.target:
        _check_space(args.target, sum(e["size"] for e in entries), force=True)
    return 0


def cmd_create(args) -> int:
    spec = specmod.normalize(specmod.from_args(args))
    entries = planner.plan(spec)
    _describe(spec, entries)
    if not os.path.isdir(args.target):
        raise Fail(f"target {args.target} is not a directory (is the volume mounted?)")
    dataset_id = args.id or f"ds-{spec['name']}-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}"
    store, root = Store(args.out, dataset_id), os.path.join(args.target, dataset_id)
    if store.exists() and not args.resume:
        raise Fail(f"{store.dir} already exists (use --resume to continue it, or another --id)")
    if os.path.exists(root) and not args.resume:
        raise Fail(f"{root} already exists (use --resume to continue it, or another --id)")
    total = sum(e["size"] for e in entries)
    _check_space(args.target, total, args.force)
    if args.dry_run:
        print(f"dry run: would write {root}")
        return 0

    print(f"writing {root}")
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, MARKER), "w") as fh:
        json.dump({"id": dataset_id, "name": spec["name"]}, fh)
    started = _now()
    mkdir_s = _mkdirs(root, entries)
    mode = spec["writers"]["checksums"]
    tasks = [{**e, "action": "create", "want_sum": _want_sum(mode, e["idx"])} for e in entries]
    rec, summary = _run_pass(store, "ops-g0.csv.gz", root, tasks, spec, 0, spec["writers"]["jobs"], args.resume)

    for e in entries:
        row = rec.rows.get(e["idx"])
        e["sha256"] = row["sha256"] if row else ""
        e["state"] = "present" if row and not row["error"] else "failed"
    meta = {
        "id": dataset_id, "name": spec["name"], "spec": spec, "created": started, "deleted": None,
        "generations": [{
            "gen": 0, "action": "create", "started": started, "finished": _now(), **_where(args.target, spec["writers"]["side"]),
            "files": len(entries), "bytes_planned": total, "mkdir_s": mkdir_s,
            "manifest": store.write_manifest(0, entries), "ops": "ops-g0.csv.gz", **summary,
        }],
        "verifications": [],
    }
    store.save(meta)
    _print_summary(summary, rec.errors)
    print(f"dataset {dataset_id}: files in {root}, records in {store.dir}")
    return 1 if rec.errors else 0


# ---------------------------------------------------------------- modify

def _open(args) -> tuple:
    store = Store(args.out, args.dataset)
    if not store.exists():
        raise Fail(f"no dataset {args.dataset} in {args.out} (see: list)")
    meta = store.load()
    if meta.get("deleted"):
        raise Fail(f"dataset {args.dataset} was deleted on {meta['deleted']}")
    last = meta["generations"][-1]
    target = args.target or last["target"]
    root = os.path.join(target, meta["id"])
    if not os.path.exists(os.path.join(root, MARKER)):
        raise Fail(f"{root} is not this dataset (no {MARKER}); check --target")
    return store, meta, target, root


def cmd_modify(args) -> int:
    store, meta, target, root = _open(args)
    spec = meta["spec"]
    gen = meta["generations"][-1]["gen"] + 1
    entries = store.read_manifest(gen - 1)
    by_idx = {e["idx"]: e for e in entries}
    present = [e for e in entries if e["state"] == "present"]
    jobs = args.jobs or spec["writers"]["jobs"]
    run_spec = json.loads(json.dumps(spec))
    if args.fsync:
        run_spec["writers"]["fsync"] = True
    params = {"mode": args.mode}
    new_entries, mkdir_s = [], 0.0

    if args.mode == "create":
        sub = specmod.normalize({
            "name": spec["name"], "seed": spec["seed"], "layout": spec["layout"], "data": spec["data"],
            "size": specmod.from_args(args)["size"],
        })
        first = max(by_idx) + 1 if by_idx else 0
        new_entries = planner.plan(sub, gen, first, prefix=f"_gen{gen}/")
        need = sum(e["size"] for e in new_entries)
        _check_space(target, need, args.force)
        mkdir_s = _mkdirs(root, new_entries)
        mode = spec["writers"]["checksums"]
        tasks = [{**e, "action": "create", "want_sum": _want_sum(mode, e["idx"])} for e in new_entries]
        params.update(files=len(new_entries), bytes=need)
    else:
        if not 0 < args.percent <= 100:
            raise Fail("--percent must be between 0 and 100")
        count = min(len(present), max(1, math.ceil(len(present) * args.percent / 100)))
        rng = random.Random(f"{spec['seed']}/select/{gen}")
        chosen = sorted(rng.sample(present, count), key=lambda e: e["idx"])
        params.update(percent=args.percent, files=count)
        tasks = []
        if args.mode in ("overwrite", "append"):
            nbytes = parse_size(args.bytes)
            if nbytes < 1:
                raise Fail("--bytes must be at least 1")
            params.update(bytes=nbytes)
            if args.mode == "append":
                _check_space(target, nbytes * count, args.force)
            for e in chosen:
                task = {**e, "action": args.mode, "want_sum": bool(e["sha256"])}
                if args.mode == "append":
                    task["length"] = nbytes
                else:
                    task["length"] = min(nbytes, e["size"])
                    room = e["size"] - task["length"]
                    task["offset"] = 0 if args.range == "start" else rng.randrange(0, room + 1, 4096) if room >= 4096 else 0
                tasks.append(task)
            if args.mode == "overwrite":
                params.update(range=args.range)
        else:
            ops = [op.strip() for op in args.ops.split(",")]
            bad = set(ops) - set(META_OPS)
            if bad:
                raise Fail(f"--ops must be from {META_OPS}, got {sorted(bad)}")
            params.update(ops=ops)
            for i, e in enumerate(chosen):
                op = ops[i % len(ops)]
                task = {**e, "action": op}
                if op == "rename":
                    task["new_path"] = f"{e['path']}.g{gen}"
                tasks.append(task)

    print(f"generation {gen} of {meta['id']}: {args.mode} on {len(tasks)} files, side {args.side}, in {root}")
    if args.dry_run:
        print("dry run: nothing changed")
        return 0
    started = _now()
    ops_name = f"ops-g{gen}.csv.gz"
    rec, summary = _run_pass(store, ops_name, root, tasks, run_spec, gen, jobs)

    new_by_idx = {e["idx"]: e for e in new_entries}
    for task in tasks:
        row = rec.rows.get(task["idx"])
        failed = row is None or bool(row["error"])
        if task["action"] == "create":
            new_by_idx[task["idx"]].update(sha256="" if failed else row["sha256"],
                                           state="failed" if failed else "present")
            continue
        if failed:
            continue   # the file is as it was
        entry = by_idx[task["idx"]]
        if task["action"] == "append":
            entry["size"] += task["length"]
        if task["action"] in ("append", "overwrite") and entry["sha256"]:
            entry["sha256"] = row["sha256"]
        if task["action"] == "rename":
            entry["path"] = task["new_path"]
        if task["action"] == "delete":
            entry["state"] = "deleted"
    entries += new_entries

    meta["generations"].append({
        "gen": gen, "action": "modify", "params": params, "started": started, "finished": _now(),
        **_where(target, args.side), "files": len(tasks), "mkdir_s": mkdir_s,
        "manifest": store.write_manifest(gen, entries), "ops": ops_name, **summary,
    })
    store.save(meta)
    _print_summary(summary, rec.errors)
    return 1 if rec.errors else 0


# ---------------------------------------------------------------- verify / delete / list

def cmd_verify(args) -> int:
    store, meta, target, root = _open(args)
    gen = meta["generations"][-1]["gen"]
    entries = [e for e in store.read_manifest(gen) if e["state"] == "present"]
    with_sum = sum(1 for e in entries if e["sha256"])
    print(f"verifying {meta['id']}@g{gen} in {root}: {len(entries)} files (size), {with_sum} with checksum")
    started = _now()
    ops_name = f"ops-verify-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}.csv.gz"
    tasks = [{**e, "action": "verify"} for e in entries]
    rec, summary = _run_pass(store, ops_name, root, tasks, meta["spec"], gen,
                             args.jobs or meta["spec"]["writers"]["jobs"])
    meta["verifications"].append({
        "gen": gen, "started": started, "finished": _now(), **_where(target, args.side),
        "files": len(entries), "checksummed": with_sum, "ops": ops_name, **summary,
    })
    store.save(meta)
    _print_summary(summary, rec.errors)
    print("verify OK" if not rec.errors else "verify FAILED")
    return 1 if rec.errors else 0


def cmd_delete(args) -> int:
    store, meta, target, root = _open(args)
    if not args.yes:
        raise Fail(f"this deletes every file under {root}; repeat with --yes")
    shutil.rmtree(root)
    meta["deleted"] = _now()
    store.save(meta)
    print(f"deleted {root}; the records stay in {store.dir}")
    return 0


def cmd_list(args) -> int:
    if not os.path.isdir(args.out):
        print(f"no datasets in {args.out}")
        return 0
    for name in sorted(os.listdir(args.out)):
        store = Store(args.out, name)
        if not store.exists():
            continue
        meta = store.load()
        last = meta["generations"][-1]
        entries = [e for e in store.read_manifest(last["gen"]) if e["state"] == "present"]
        state = f"deleted {meta['deleted']}" if meta.get("deleted") else last["target"]
        print(f"{meta['id']}  g{last['gen']}  {len(entries)} files  "
              f"{format_size(sum(e['size'] for e in entries))}  {state}")
    return 0


# ---------------------------------------------------------------- arguments

def _sizing(p) -> None:
    g = p.add_argument_group("size (any two of the three)")
    g.add_argument("--files", type=int, help="number of files")
    g.add_argument("--file-size", help="one size (64KiB) or a range (1MiB-64MiB)")
    g.add_argument("--size-mix", help="weighted mix, e.g. 70:4KiB-64KiB,25:1MiB-16MiB,5:1GiB")
    g.add_argument("--total", help="total size, e.g. 500GiB")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bench dataset", description=__doc__.strip().splitlines()[0])
    parser.add_argument("--out", default="results/datasets", help="where dataset records are kept (default: %(default)s)")
    sub = parser.add_subparsers(dest="command", required=True)

    for name, func, text in (("plan", cmd_plan, "show what a spec would create, without writing"),
                             ("create", cmd_create, "write a new dataset")):
        p = sub.add_parser(name, help=text)
        p.set_defaults(func=func)
        p.add_argument("--spec", help="spec file (.yaml or .json); flags below override it")
        p.add_argument("--name", help="dataset name")
        _sizing(p)
        p.add_argument("--target", required=(name == "create"),
                       help="directory to write into, e.g. /mnt/fsxn/vol_origin")
        p.add_argument("--side", choices=specmod.SIDES, help="which side --target is on (default: origin)")
        p.add_argument("--seed", type=int)
        p.add_argument("--jobs", type=int, help="parallel writer processes")
        p.add_argument("--block-size")
        p.add_argument("--files-per-dir", type=int)
        p.add_argument("--depth", type=int, help="directory levels (0 = all files in one directory)")
        p.add_argument("--compress-percent", type=int)
        p.add_argument("--dedupe-percent", type=int)
        p.add_argument("--checksums", choices=specmod.CHECKSUM_MODES)
        p.add_argument("--fsync", action="store_true", help="fsync every file before closing it")
        if name == "create":
            p.add_argument("--id", help="dataset id (default: ds-<name>-<utc time>)")
            p.add_argument("--resume", action="store_true", help="continue an interrupted create")
            p.add_argument("--force", action="store_true", help="ignore the free-space check")
            p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("modify", help="change an existing dataset (a new generation), from either side")
    p.set_defaults(func=cmd_modify)
    p.add_argument("dataset", help="dataset id")
    p.add_argument("--mode", required=True, choices=MODES,
                   help="create = new files; overwrite / append = change data; metadata = rename, chmod, delete")
    p.add_argument("--side", required=True, choices=specmod.SIDES, help="which side --target is on")
    p.add_argument("--target", help="mount to work through, e.g. /mnt/fsxn/vol_cache (default: where it was last written)")
    p.add_argument("--percent", type=float, default=10, help="share of the files to touch (default: %(default)s)")
    p.add_argument("--bytes", default="1MiB", help="bytes to overwrite or append per file (default: %(default)s)")
    p.add_argument("--range", choices=("random", "start"), default="random", help="where to overwrite")
    p.add_argument("--ops", default="rename,chmod,delete", help="metadata operations, in turn")
    _sizing(p)
    p.add_argument("--jobs", type=int)
    p.add_argument("--fsync", action="store_true")
    p.add_argument("--force", action="store_true", help="ignore the free-space check")
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("verify", help="check sizes and checksums against the latest manifest")
    p.set_defaults(func=cmd_verify)
    p.add_argument("dataset")
    p.add_argument("--side", required=True, choices=specmod.SIDES)
    p.add_argument("--target", help="mount to read through (default: where it was last written)")
    p.add_argument("--jobs", type=int)

    p = sub.add_parser("delete", help="delete a dataset's files (its records are kept)")
    p.set_defaults(func=cmd_delete)
    p.add_argument("dataset")
    p.add_argument("--target")
    p.add_argument("--yes", action="store_true")

    p = sub.add_parser("list", help="list the datasets recorded in --out")
    p.set_defaults(func=cmd_list)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (Fail, specmod.SpecError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
