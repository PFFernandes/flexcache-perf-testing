# Test bench CloudWatch dashboard: one consolidated view of a lab, origin on the left and
# cache on the right, each in its own region:
#
#   test bench (namespace FlexCacheBench, pushed by bench-results-sync AFTER each test)
#     dataset write throughput and open / write / close latency (p50, p99)
#     host CPU, memory, network; NFS round-trip and operations per NFS operation;
#     EC2 network-limit counters; ping to both file systems
#   AWS (published by AWS itself)
#     FSx for ONTAP: throughput and IOPS per volume, read/write latency, CPU and network utilization
#     EC2: client CPU (5-minute basic monitoring)
#
# SEARCH expressions are used throughout, so new mounts, NFS operations or volumes show up
# without changing the dashboard.
#
# Resources:
#   aws_cloudwatch_dashboard.this   in the provider's region (origin)

locals {
  ns  = var.namespace
  lab = var.lab

  # SEARCH over the bench namespace for one side. dims = the metric's extra dimensions.
  bench = { for side, s in var.sides : side => {
    for k, m in {
      cpu       = { metric = "CpuBusyPercent", dims = "", stat = "Average" }
      mem       = { metric = "MemoryUsedPercent", dims = "", stat = "Average" }
      net       = { metric = "NetworkBytesPerSecond", dims = ",Direction", stat = "Average" }
      nfs_rtt   = { metric = "NfsRttMs", dims = ",Mount,Op", stat = "Average" }
      nfs_ops   = { metric = "NfsOpsPerSecond", dims = ",Mount,Op", stat = "Average" }
      nfs_bytes = { metric = "NfsBytesPerSecond", dims = ",Direction,Mount", stat = "Average" }
      ena       = { metric = "EnaAllowanceExceeded", dims = ",Counter", stat = "Sum" }
      ping      = { metric = "PingRttMs", dims = ",Target", stat = "Average" }
      ds_bytes  = { metric = "DatasetBytesWritten", dims = ",Dataset", stat = "Sum" }
      ds_files  = { metric = "DatasetFilesWritten", dims = ",Dataset", stat = "Sum" }
      open_p50  = { metric = "DatasetOpenLatency", dims = ",Dataset", stat = "p50" }
      open_p99  = { metric = "DatasetOpenLatency", dims = ",Dataset", stat = "p99" }
      close_p99 = { metric = "DatasetCloseLatency", dims = ",Dataset", stat = "p99" }
      write_p99 = { metric = "DatasetWriteTime", dims = ",Dataset", stat = "p99" }
      } : k => format("SEARCH('{%s,Lab,Side%s} MetricName=\"%s\" Lab=\"%s\" Side=\"%s\"', '%s', 60)",
    local.ns, m.dims, m.metric, local.lab, side, m.stat)
  } }

  # SEARCH over AWS/FSx volume metrics of one file system.
  fsx = { for side, s in var.sides : side => {
    for k, m in {
      read_bytes  = { metric = "DataReadBytes" }
      write_bytes = { metric = "DataWriteBytes" }
      read_ops    = { metric = "DataReadOperations" }
      write_ops   = { metric = "DataWriteOperations" }
      read_time   = { metric = "DataReadOperationTime" }
      write_time  = { metric = "DataWriteOperationTime" }
      } : k => format("SEARCH('{AWS/FSx,FileSystemId,VolumeId} MetricName=\"%s\" FileSystemId=\"%s\"', 'Sum', 60)",
    m.metric, s.file_system_id)
  } if s.file_system_id != null }

  sides_order = [for side in ["origin", "cache"] : side if contains(keys(var.sides), side)]
  col         = { for side in local.sides_order : side => side == "origin" ? 0 : 12 }

  # One column of widgets per side: [title, metrics, extra properties].
  column = { for side, s in var.sides : side => concat([
    {
      title = "${side}: dataset write (MB/s) and files per minute"
      metrics = [
        [{ id = "b", expression = local.bench[side].ds_bytes, visible = false }],
        [{ id = "mbs", expression = "b/60000000", label = "MB/s" }],
        [{ id = "f", expression = local.bench[side].ds_files, label = "files/min", yAxis = "right" }],
      ]
    },
    {
      title = "${side}: dataset open / write / close latency (µs)"
      metrics = [
        [{ id = "o50", expression = local.bench[side].open_p50, label = "open p50" }],
        [{ id = "o99", expression = local.bench[side].open_p99, label = "open p99" }],
        [{ id = "w99", expression = local.bench[side].write_p99, label = "write p99" }],
        [{ id = "c99", expression = local.bench[side].close_p99, label = "close p99" }],
      ]
    },
    {
      title = "${side}: client CPU busy and memory used (%)"
      metrics = [
        [{ id = "cpu", expression = local.bench[side].cpu, label = "CPU busy" }],
        [{ id = "mem", expression = local.bench[side].mem, label = "memory used" }],
      ]
      yAxis = { left = { min = 0, max = 100 } }
    },
    {
      title   = "${side}: client network (bytes/s)"
      metrics = [[{ id = "net", expression = local.bench[side].net }]]
    },
    {
      title   = "${side}: NFS round-trip per operation (ms)"
      metrics = [[{ id = "rtt", expression = local.bench[side].nfs_rtt }]]
    },
    {
      title   = "${side}: NFS operations per second"
      metrics = [[{ id = "ops", expression = local.bench[side].nfs_ops }]]
    },
    {
      title   = "${side}: NFS bytes per second, per mount"
      metrics = [[{ id = "nb", expression = local.bench[side].nfs_bytes }]]
    },
    {
      title   = "${side}: EC2 network limits hit (packets per minute; 0 = never the bottleneck)"
      metrics = [[{ id = "ena", expression = local.bench[side].ena }]]
    },
    {
      title   = "${side}: ping to the file systems' NFS IPs (ms)"
      metrics = [[{ id = "ping", expression = local.bench[side].ping }]]
    },
    ], s.file_system_id == null ? [] : [
    {
      title = "${side}: FSx for ONTAP throughput per volume (MB/s)"
      metrics = [
        [{ id = "rb", expression = local.fsx[side].read_bytes, visible = false }],
        [{ id = "wb", expression = local.fsx[side].write_bytes, visible = false }],
        [{ id = "r", expression = "rb/60000000", label = "read" }],
        [{ id = "w", expression = "wb/60000000", label = "write" }],
      ]
    },
    {
      title = "${side}: FSx for ONTAP IOPS and latency (ms), all volumes"
      metrics = [
        [{ id = "ro", expression = local.fsx[side].read_ops, visible = false }],
        [{ id = "wo", expression = local.fsx[side].write_ops, visible = false }],
        [{ id = "rt", expression = local.fsx[side].read_time, visible = false }],
        [{ id = "wt", expression = local.fsx[side].write_time, visible = false }],
        [{ id = "riops", expression = "SUM(ro)/60", label = "read IOPS" }],
        [{ id = "wiops", expression = "SUM(wo)/60", label = "write IOPS" }],
        [{ id = "rlat", expression = "IF(SUM(ro) > 0, SUM(rt)/SUM(ro)*1000, 0)", label = "read latency (ms)", yAxis = "right" }],
        [{ id = "wlat", expression = "IF(SUM(wo) > 0, SUM(wt)/SUM(wo)*1000, 0)", label = "write latency (ms)", yAxis = "right" }],
      ]
    },
    {
      title = "${side}: FSx for ONTAP CPU and network utilization (%)"
      metrics = [
        [{ id = "fcpu", expression = format("SEARCH('{AWS/FSx} MetricName=\"CPUUtilization\" \"%s\"', 'Average', 60)", s.file_system_id) }],
        [{ id = "fnet", expression = format("SEARCH('{AWS/FSx} MetricName=\"NetworkThroughputUtilization\" \"%s\"', 'Average', 60)", s.file_system_id) }],
      ]
    },
    ], s.instance_id == null ? [] : [
    {
      title   = "${side}: EC2 client CPU (%, AWS 5-minute data)"
      metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", s.instance_id, { stat = "Average", period = 300 }]]
    },
  ]) }

  header = {
    type   = "text"
    x      = 0
    y      = 0
    width  = 24
    height = 3
    properties = {
      markdown = join("\n", concat([
        "# FlexCache test bench: ${var.lab}",
        "Bench metrics (namespace `${local.ns}`) are pushed **after each test** by `bench-results-sync`, so a running test appears when it ends. FSx and EC2 metrics come from AWS directly. Full detail stays on the results volume.",
        ], [for side in local.sides_order : "**${side}** (${var.sides[side].region}): file system `${coalesce(var.sides[side].file_system_id, "-")}`, client `${coalesce(var.sides[side].instance_id, "-")}`"],
        var.results_volume_id == null ? [] : ["Results volume `vol_bench`: `${var.results_volume_id}` (its traffic shows up in the FSx volume charts)"]
      ))
    }
  }

  widgets = concat([local.header], flatten([
    for side in local.sides_order : [
      for i, w in local.column[side] : {
        type   = "metric"
        x      = local.col[side]
        y      = 3 + i * 6
        width  = 12
        height = 6
        properties = merge({
          title   = w.title
          region  = var.sides[side].region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = w.metrics
        }, try({ yAxis = w.yAxis }, {}))
      }
    ]
  ]))
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.dashboard_name
  dashboard_body = jsonencode({ widgets = local.widgets })
}

data "aws_region" "current" {}
