# 11-bench-telemetry

The OpenTelemetry Collector and `bench-probe` on the Linux EC2 clients. **During a test everything
is written to local disk** (`/var/lib/bench/staging`) and copied to the **results volume**
(`vol_bench`, `modules/12-bench-results-volume`) only after the test, so the results never add NFS
load to the file systems being measured. No results go to S3. Called by `stacks/05-bench` when `telemetry = true`, after `09-bench-deploy`
(the probe runs from `/opt/bench`).

## What it does

| Step | Where | |
|---|---|---|
| 1. stage | operator machine, `files/stage.sh` | Downloads `otelcol-contrib_<version>_linux_<arch>.rpm` from the [Collector releases](https://github.com/open-telemetry/opentelemetry-collector-releases/releases), checks its SHA-256 against `collector_sha256`, and copies it to `vendor/otelcol-contrib/<version>/` in the package bucket of each region (`stacks/00-bench-store`), skipped when already there. Cached in `~/.cache/flexcache-bench`. The bucket only delivers the package: the clients have no internet. |
| 2. access | IAM | Each client role may read `vendor/*` in its region's package bucket. Nothing else in S3. |
| 3. install | client, `files/install.sh` → `files/remote.sh` over SSM | Mounts the results volume at `/mnt/fsxn/vol_bench` (fstab entry, also picked up by the client's mount timer) and creates the local staging folder. Installs the RPM from the bucket (SHA-256 checked again), runs `otelcol-contrib validate` on the new config before it replaces the old one, starts `otelcol-contrib` and `bench-probe`, writes `/etc/bench/bench.env` and `labs/<lab>/lab.json` on the volume, then waits until telemetry is being staged. |

`terraform destroy` stops both services, runs a **final copy** of everything staged to the results
volume (and fails, removing nothing, if it can't), then removes the package and unmounts the volume.
Everything on the volume stays.

## Staging, then copying

| While a test runs (local) | After it (results volume) |
|---|---|
| `/var/lib/bench/staging/telemetry/<lab>/<side>/<instance-id>/metrics*.json` | `/mnt/fsxn/vol_bench/telemetry/...` |
| `/var/lib/bench/staging/datasets/<dataset-id>/` | `/mnt/fsxn/vol_bench/datasets/<dataset-id>/` |
| `/var/lib/bench/staging/logs/` | `/mnt/fsxn/vol_bench/logs/` |

The copy is `bench-results-sync` (`bench/results/sync.py`, installed by `09-bench-deploy`, runs as
root). It runs after each `bench-dataset` command and each `bench-datasets-nfs` batch, by hand, and
on destroy. It moves finished dataset records (skipping any a running command still holds), copies
and then removes rotated telemetry files, and copies the file the Collector is still writing as a
snapshot. With `cloudwatch_namespace` set (stack 05, `cloudwatch = true`), it first pushes the new
minutes of telemetry and the new dataset timings to CloudWatch (`bench/results/cloudwatch.py`, through
the endpoint from `13-bench-cloudwatch`); a failed push is retried next time and never stops the
copy. Local telemetry is capped at `local_buffer_mib` (2 GiB, in `rotate_mib` = 50 MiB files):
if nothing is copied for days, the oldest local files are dropped rather than filling the disk.

## What is collected

| Source | Metrics | Every |
|---|---|---|
| Collector `hostmetrics` | `system.cpu.*` (incl. utilization), `system.memory.*` (incl. utilization), `system.cpu.load_average.*`, `system.disk.*`, `system.network.*`, `system.paging.*` | `interval_s` (5 s) |
| `bench-probe` | `bench.nfs.ops`, `bench.nfs.rtt`, `bench.nfs.execute` per mount and NFS operation; `bench.nfs.bytes` per mount and direction | `interval_s` |
| `bench-probe` | `bench.ena.allowance_exceeded` per ENA counter (needs `ethtool`, installed if missing) | `interval_s` |
| `bench-probe` | `bench.ping.rtt`, `bench.ping.loss` to the origin and cache NFS IPs | `ping_interval_s` (10 s) |
| `bench-ontap` (origin client, `ontap` set) | per watched volume of both clusters: `ontap.volume.ops`, `.latency` (µs), `.throughput` per op type; `ontap.volume.nfs.ops`, `.nfs.latency` per NFS operation; FlexCache: `ontap.flexcache.requested_blocks`, `.miss_blocks`, `.miss_percent`; **between the file systems, both directions:** `ontap.fs.ping_rtt` (`method` = `network-ping` from each intercluster LIF to the other cluster's intercluster IPs, or `cluster-peer-ping`; REST CLI passthrough, switched off if FSx refuses it); fallback `ontap.intercluster.ping_rtt` (ICMP from the origin client) | 15 s, pings 30 s |

Every data point carries `bench.lab`, `bench.side`, `host.id` (instance ID), `cloud.provider`,
`cloud.region`.

## On the results volume

```
/mnt/fsxn/vol_bench/
  telemetry/<lab>/<side>/<instance-id>/metrics.json         OTLP JSON, one batch per line (Collector file exporter)
  telemetry/<lab>/<side>/<instance-id>/metrics-<time>.json  rotated files
  datasets/<dataset-id>/                                    dataset records (bench-dataset)
  logs/                                                     bench-datasets-nfs --background logs
  labs/<lab>/lab.json                                       regions, file systems, clients, results volume (written at install)
```

`datasets/`, `logs/` and the top level are shared by every user and both clients (mode 1777; the
bench commands create files writable by all).

On a client: `systemctl status otelcol-contrib bench-probe`, `journalctl -u otelcol-contrib`,
config in `/etc/otelcol-contrib/config.yaml` and `/etc/bench/probe.json`.

## Variables

| Variable | Default | |
|---|---|---|
| `name`, `lab` | – | IAM policy prefix; lab name in the results paths and attributes |
| `clients` | – | `{ side = { region, instance_id, role_name, bucket, bucket_arn, bucket_region, ping_targets } }` (bucket = package bucket of that region) |
| `results` | – | `{ volume_id, volume_name, side, nfs_ip, junction_path, mount_point, nfs_options }` |
| `cloudwatch_namespace` | `null` | CloudWatch namespace to push to after each test; `null` = no push |
| `ontap` | `null` | bench-ontap: `{ secret_arn, secret_region, clusters = { origin/cache = { mgmt_ip, volumes, intercluster_ips } } }`; uses the fsxadmin credentials; `null` = off |
| `lab_info` | `{}` | content of `lab.json` |
| `collector_version` | `0.165.0` | change together with `collector_sha256` |
| `collector_sha256` | amd64, arm64 of 0.165.0 | from the release's `.sha256` files |
| `collector_architectures` | `["amd64"]` | `arm64` for Graviton clients |
| `interval_s` / `ping_interval_s` / `flush_s` | 5 / 10 / 10 | seconds |
| `staging_dir` | `/var/lib/bench/staging` | local folder written during tests |
| `rotate_mib` | 50 | size at which the Collector starts a new file |
| `local_buffer_mib` | 2048 | local disk for telemetry not yet copied |
| `memory_limit_mib` | 256 | Collector memory limit |

Outputs: `telemetry_files` (on the volume), `staging_dir`, `results_mount`, `ontap_poller`, `collector_version`.

Needs on the operator machine: `curl`, `sha256sum` or `shasum`, internet access to GitHub, and the
AWS CLI with S3 (package upload) and SSM Run Command permissions.
