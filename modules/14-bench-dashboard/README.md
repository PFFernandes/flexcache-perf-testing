# 14-bench-dashboard

One Amazon CloudWatch dashboard per lab, `<creator>-<project>-bench`: the **consolidated view** of
the test bench. Origin on the left, cache on the right, each widget in its own side's region (so it
works cross-region). Called by `stacks/05-bench` when `telemetry = true` and `cloudwatch = true`;
the URL is in `./tf.sh 05-bench output dashboard`.

| Row | Origin (left) and cache (right) | Source |
|---|---|---|
| 1 | Dataset write throughput (MB/s) and files per minute | bench, after each test |
| 2 | Dataset open, write and close latency: p50 / p99 (µs) | bench, after each test |
| 3 | Client CPU busy and memory used (%) | bench (Collector host metrics) |
| 4 | Client network (bytes/s) | bench (Collector host metrics) |
| 5 | NFS round-trip per NFS operation (ms) | bench (bench-probe) |
| 6 | NFS operations per second | bench (bench-probe) |
| 7 | NFS bytes per second, per mount | bench (bench-probe) |
| 8 | EC2 network limits hit (ENA allowance counters) | bench (bench-probe) |
| 9 | Ping to both file systems' NFS IPs (ms) | bench (bench-probe) |
| 10 | FSx for ONTAP throughput per volume (MB/s) | AWS/FSx |
| 11 | FSx for ONTAP read/write IOPS and latency (ms) | AWS/FSx |
| 12 | FSx for ONTAP CPU and network utilization (%) | AWS/FSx |
| 13 | EC2 client CPU (5-minute basic monitoring) | AWS/EC2 |

- **Bench metrics** (namespace `FlexCacheBench`) arrive **when a test ends**, as one-minute
  statistics; FSx and EC2 metrics are published by AWS continuously.
- Widgets use CloudWatch `SEARCH` expressions, so new mounts, NFS operations, datasets and volumes
  appear without changing the dashboard.
- The FSx volume charts include `vol_bench`; the header shows its volume ID.
- **Retention** is CloudWatch's: 1-minute data for 15 days, 5-minute for 63 days, 1-hour for 15
  months. The full-resolution record stays on `vol_bench` and its final backup.

| Variable | Default | |
|---|---|---|
| `dashboard_name` | – | from stack 05 |
| `lab` | – | the `Lab` dimension |
| `namespace` | `FlexCacheBench` | |
| `sides` | – | `{ origin = { region, file_system_id, instance_id }, cache = {...} }` |
| `results_volume_id` | `null` | shown in the header |

Outputs: `dashboard_name`, `url`.
