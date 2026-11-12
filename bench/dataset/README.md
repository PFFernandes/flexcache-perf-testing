# bench/dataset – module 1: datasets

Creates the files the performance tests read and change. Standard-library Python only (3.9+), so it
runs unchanged on the Amazon Linux 2023 clients. Design: [docs/test-bench-design.md](../../docs/test-bench-design.md) §4.

Datasets are created **by hand by the users**: log in to the client that has the volume mounted
(origin client for `vol_origin`, cache client for `vol_cache`) and run the commands below. Nothing
creates, changes or deletes datasets automatically. The step-by-step procedure is in the
[top-level README](../../README.md#creating-the-datasets-users-by-hand).

**On the EC2 clients** it is installed by `stacks/05-bench` (see the top-level README) as the
`bench-dataset` command, usable from any folder:

```bash
bench-dataset --help
```

**Anywhere else** (e.g. the operator machine, against a local folder), from the repository root:

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

## T-shirt sizes on NFS

Six ready-made datasets, one profile each in `profiles/datasets/` (KiB, MiB, GiB are powers of 1024):

| Size | File size | Total | Files | Write time at 128 MB/s, at best |
|---|---|---|---|---|
| `small` | 64 KiB | 10 GiB | 163 840 | ~1.5 min (in practice longer: small files are metadata-bound) |
| `2xsmall` | 1 MiB | 50 GiB | 51 200 | ~7 min |
| `medium` | 5 MiB | 100 GiB | 20 480 | ~14 min |
| `2xmedium` | 10 MiB | 200 GiB | 20 480 | ~28 min |
| `large` | 50 MiB | 250 GiB | 5 120 | ~35 min |
| `2xlarge` | 1 GiB | 300 GiB | 300 | ~42 min |
| **all** | | **910 GiB** | | **~2 h** |

The times assume the default FSx throughput capacity of 128 MB/s; the client's own network limit
(small with `t3.small`) can make them longer.

`bench-datasets-nfs` (installed on the clients by stack 05) creates any of them on an NFS mount,
one after the other:

```bash
bench-datasets-nfs --dry-run all                      # plan + space check, writes nothing
bench-datasets-nfs --scale 0.01 small medium          # 1 % trial run first
bench-datasets-nfs small 2xsmall medium               # the real thing
bench-datasets-nfs --background all                   # keeps running after you log out
```

- **NFS only:** it refuses a target that isn't an NFS mount. The default target is
  `/mnt/fsxn/vol_origin`; `--target` and `--side cache` write through `/mnt/fsxn/vol_cache` instead.
- **Space is checked for the whole selection** before anything is written (plus 10 %). With the
  lab defaults **all six don't fit**: 910 GiB against an 800 GiB `vol_origin`. The error says which
  sizes fit; delete older datasets, choose fewer sizes, or make `vol_origin` bigger
  (`origin_volume.size_gib` in `stacks/02-fsxn`). Keep the FlexCache size (500 GiB by default) in
  mind too when the cache will read them.
- Each size becomes its own dataset (`ds-<size>-<utc time>`) with its own manifest and per-file
  timings. It stops at the first failure unless `--keep-going`.
- With the results volume, all records and the log are copied to `vol_bench` **once, after the
  last size**, not between sizes.
- `--background` writes the output to `/var/lib/bench/staging/logs/datasets-nfs-<user>-<time>.log`
  (copied to `vol_bench/logs/` at the end; `~/bench-results/logs/` without the results volume) and prints the
  `tail -f` command. Use it for anything that takes longer than your SSM session.
- `--scale F` writes F × each total with the same file size, for trial runs. Below 0.0034 the
  2xlarge size holds less than one 1 GiB file and becomes one shorter file (the script warns).
- Other options: `--jobs N`, `--force` (skip the space check), `--allow-non-nfs` (testing only).

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

## Read (both sides)

Times reading the dataset's files through either side: the origin client reads
`/mnt/fsxn/vol_origin` (baseline), the cache client `/mnt/fsxn/vol_cache` (through FlexCache).

```bash
bench-dataset read <id> --side origin                       # 2 passes, whole files
bench-dataset read <id> --side cache                        # same through FlexCache: pass 1 cold, pass 2 warm
bench-dataset read <id> --side cache --mode open            # open + close only: metadata cost
bench-dataset read <id> --side cache --mode first           # open, first block, close
bench-dataset read <id> --side cache --files 1000 --passes 3 --order shuffled
```

| Per file | From | To |
|---|---|---|
| `open` | before `open()` | it returns |
| `first byte` | after the open | the first read returns data |
| `whole file` | after the open | the last byte is read (`--mode full`) |
| `close` | before `close()` | it returns |

Per pass: files, bytes, wall-clock time ("how long to read XX GB in N files"), MB/s, files/s,
the open time summed over all files, and p50 / p90 / p99 / p99.9 / max of the four steps.

- **Passes** (`--passes`, default 2): the client's page, dentry and inode caches are dropped before
  each pass (needs `sudo`, which `ssm-user` and `ec2-user` have; recorded as `client_cache`).
  `--keep-client-cache` keeps them. Through FlexCache, pass 1 is cold only if the cache hasn't read
  these files before; use a fresh dataset or generation for a guaranteed cold read.
- **Records:** `reads/read-<time>-<side>-p<N>.json` (summary) and `reads/ops-read-<time>-<side>-p<N>.csv.gz`
  (one row per file) in the dataset's records. Each read is its own file, so both clients can read
  the same dataset at the same time. `dataset.json` isn't changed.
- `--block-size` (1 MiB) is the size of each read call; `--jobs` the parallel readers.

## Verify, list, delete

```bash
bench-dataset verify <id> --side origin --target /mnt/fsxn/vol_origin   # sizes + checksums
bench-dataset list
bench-dataset delete <id> --yes          # removes the files, keeps the records
```

Verifying on the origin after a cache-side modify checks that the change arrived there.

## What it records

On the clients with the results volume (stack 05 with `telemetry = true`): **while the command
runs**, in the local staging folder `/var/lib/bench/staging/datasets/<dataset-id>/`; **when it
ends**, the `bench-dataset` command copies them to `/mnt/fsxn/vol_bench/datasets/<dataset-id>/`
(and removes the local copy). Nothing is written to the results volume during a test. Records on
`vol_bench` are shared by every user and both clients; a command reads them back from there before
it starts. `list` shows where each dataset is (`[staged]` or `[vol_bench]`). Without the results volume, in
`~/bench-results/datasets/<dataset-id>/` of the user. With `python3 -m bench.dataset` elsewhere, in
`results/datasets/<dataset-id>/`. `$BENCH_OUT`, or `--out` (which goes **before** the command),
overrides all of these:

| File | Content |
|---|---|
| `dataset.json` | The resolved spec, and per generation: side, mount and its NFS options, host, kernel, duration, bytes, throughput, and latency percentiles of open / write / fsync / close. |
| `manifest-g<N>.csv.gz` | Every file after generation N: index, path, size, SHA-256 (if checksummed), state. |
| `ops-g<N>.csv.gz` | One row per file operation: timestamp and the time of open, I/O, fsync and close in microseconds. |

`modify`, `verify`, `delete` and `list` need these records. On the results volume anyone can use
them from either client, and they are kept in the volume's final backup when the lab is destroyed.
In `~/bench-results` they work only for that user on that client, and are deleted with the client.

## Tests

```bash
python3 -m unittest discover -s bench/tests -t .
```
