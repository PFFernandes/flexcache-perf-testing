# bench/dataset – module 1: datasets

Creates the files the performance tests read and change. Standard-library Python only (3.9+), so it
runs unchanged on the Amazon Linux 2023 clients. Design: [docs/test-bench-design.md](../../docs/test-bench-design.md) §4.

Run it **on the machine that has the volume mounted** (origin client for `vol_origin`, cache client
for `vol_cache`).

**On the EC2 clients** it is installed by `stacks/05-bench` (see the top-level README) as the
`bench-dataset` command, usable from any folder:

```bash
bench-dataset --help
```

**Anywhere else** (e.g. your Mac, against a local folder), from the repository root:

```bash
python3 -m bench.dataset --help
```

The examples below use `bench-dataset`; `python3 -m bench.dataset` takes the same arguments.

## Create

Give **any two** of file count, file size and total size; the third is worked out.

```bash
T=/mnt/fsxn/vol_origin
bench-dataset create --target $T --files 100000 --file-size 64KiB
bench-dataset create --target $T --total 200GiB --file-size 1GiB
bench-dataset create --target $T --total 500GiB --file-size 1MiB-64MiB
bench-dataset create --target $T --total 500GiB --size-mix "70:4KiB-64KiB,25:1MiB-16MiB,5:1GiB"
bench-dataset create --target $T --spec smoke
bench-dataset plan   --spec smoke      # show the plan, write nothing
```

- Files go to `<target>/<dataset-id>/`; the id is `ds-<name>-<utc time>` unless `--id` is given.
- The same spec and `--seed` always produce the same names, sizes and bytes.
- Data is random (incompressible) by default; `--compress-percent` / `--dedupe-percent` change that.
- `--side cache --target /mnt/fsxn/vol_cache` writes a new dataset through the cache instead.
- Create refuses to start without enough free space plus 10 % (`--force` overrides), and
  `--resume` continues an interrupted create.
- `--spec` takes a file path or a name from `profiles/datasets/` (`--spec smoke`).
- Spec files: `.json` always works; `.yaml` needs PyYAML on the machine (`install_packages` in stack 05).

Other settings: `--jobs` (parallel writer processes), `--block-size`, `--files-per-dir`, `--depth`,
`--checksums none|sample|all` (sample = 1 file in 100), `--fsync`.

## Modify (a new generation)

Each modify is a numbered generation with its own manifest. `--side` records where it was done;
`--target` is the mount to work through.

```bash
C=/mnt/fsxn/vol_cache
bench-dataset modify <id> --side cache --target $C --mode overwrite --percent 10 --bytes 1MiB
bench-dataset modify <id> --side cache --target $C --mode append    --percent 5  --bytes 1MiB
bench-dataset modify <id> --side cache --target $C --mode metadata  --percent 2  --ops rename,chmod,delete
bench-dataset modify <id> --side cache --target $C --mode create    --total 50GiB --file-size 4MiB
```

## Verify, list, delete

```bash
bench-dataset verify <id> --side origin --target /mnt/fsxn/vol_origin   # sizes + checksums
bench-dataset list
bench-dataset delete <id> --yes          # removes the files, keeps the records
```

Verifying on the origin after a cache-side modify checks that the change arrived there.

## What it records

In `~/bench-results/datasets/<dataset-id>/` with `bench-dataset`, `results/datasets/<dataset-id>/` with
`python3 -m bench.dataset` (change with `$BENCH_OUT`, or `--out`, which goes **before** the command):

| File | Content |
|---|---|
| `dataset.json` | The resolved spec, and per generation: side, mount and its NFS options, host, kernel, duration, bytes, throughput, and latency percentiles of open / write / fsync / close. |
| `manifest-g<N>.csv.gz` | Every file after generation N: index, path, size, SHA-256 (if checksummed), state. |
| `ops-g<N>.csv.gz` | One row per file operation: timestamp and the time of open, I/O, fsync and close in microseconds. |

`modify`, `verify` and `delete` need these records, so run them on the machine that created the
dataset (or copy the folder). Uploading them to the results store comes with the Tooling module.

## Tests

```bash
python3 -m unittest discover -s bench/tests -t .
```
