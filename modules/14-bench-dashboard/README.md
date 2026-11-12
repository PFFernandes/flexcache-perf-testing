# 14-bench-dashboard

One Amazon CloudWatch dashboard per lab, `<creator>-<project>-bench`: the **consolidated view** of
the test bench. Origin on the left, cache on the right, each widget in its own side's region (so it
works cross-region). Called by `stacks/05-bench` when `telemetry = true` and `cloudwatch = true`;
the URL is in `./tf.sh 05-bench output dashboard`.

| Row | Origin (left) and cache (right) | Source |
|---|---|---|
| 1 | Dataset write throughput (MB/s) and files per minute | bench, after each test |
| 2 | Dataset open, write and close latency: p50 / p99 (µs) | bench, after each test |
| 3 | Dataset read (MB/s) and files per minute, per pass | bench, after each read |
| 4 | Dataset read latency per pass: open, first byte, whole file (p50, p99), close (p99) | bench, after each read |
| 5 | Client CPU busy and memory used (%) | bench (Collector host metrics) |
| 6 | Client network (bytes/s) | bench (Collector host metrics) |
| 7 | NFS round-trip per NFS operation (ms) | bench (bench-probe) |
| 8 | NFS operations per second | bench (bench-probe) |
| 9 | NFS bytes per second, per mount | bench (bench-probe) |
| 10 | EC2 network limits hit (ENA allowance counters) | bench (bench-probe) |
| 11 | Ping to both file systems' NFS IPs (ms) | bench (bench-probe) |
| 12 | FSx for ONTAP throughput per volume (MB/s) | AWS/FSx |
| 13 | FSx for ONTAP read/write IOPS and latency (ms) | AWS/FSx |
| 14 | FSx for ONTAP CPU and network utilization (%) | AWS/FSx |
| 15 | EC2 client CPU (5-minute basic monitoring) | AWS/EC2 |
| 16 | ONTAP (that side's cluster): volume latency per operation type (µs) | bench-ontap |
| 17 | ONTAP: volume IOPS per operation type | bench-ontap |
| 18 | ONTAP: NFS latency per NFS operation (µs) | bench-ontap |
| 19 | cache: FlexCache miss % and blocks requested / fetched from the origin | bench-ontap |
| 20 | **Latency between the FSx file systems**, measured by ONTAP (`network ping` between intercluster LIFs, `cluster peer ping`), both directions, in both columns | bench-ontap |
| 21 | origin: fallback ICMP from the origin client to both clusters' intercluster IPs | bench-ontap |

Rows 16-21 appear when `ontap_region` is set (bench-ontap runs). The origin client polls both
clusters, so these widgets read from the origin region in both columns.

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
| `ontap_region` | `null` | where bench-ontap publishes (origin region); `null` = no ONTAP widgets |

Outputs: `dashboard_name`, `url`.
