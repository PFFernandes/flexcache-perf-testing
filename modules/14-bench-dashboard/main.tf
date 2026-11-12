# Test bench CloudWatch dashboard: one consolidated view of a lab, origin on the left and
# cache on the right, each in its own region:
#
#   test bench (namespace FlexCacheBench, pushed by bench-results-sync AFTER each test)
#     dataset write throughput and open / write / close latency (p50, p99)
#     dataset reads per pass: throughput, open / first byte / whole file / close latency
#     host CPU, memory, network; NFS round-trip and operations per NFS operation;
#     EC2 network-limit counters; ping to both file systems
#   ONTAP (bench-ontap on the origin client, both clusters, published in the origin region)
#     volume latency / IOPS / throughput, NFS latency per operation, FlexCache miss %,
#     latency between the FSx file systems (ONTAP network ping / cluster peer ping), both columns
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
      rd_bytes  = { metric = "DatasetBytesRead", dims = ",Dataset,Pass", stat = "Sum" }
      rd_files  = { metric = "DatasetFilesRead", dims = ",Dataset,Pass", stat = "Sum" }
      rd_open50 = { metric = "DatasetReadOpenLatency", dims = ",Dataset,Pass", stat = "p50" }
      rd_open99 = { metric = "DatasetReadOpenLatency", dims = ",Dataset,Pass", stat = "p99" }
      rd_first  = { metric = "DatasetFirstByteLatency", dims = ",Dataset,Pass", stat = "p50" }
      rd_first9 = { metric = "DatasetFirstByteLatency", dims = ",Dataset,Pass", stat = "p99" }
      rd_whole  = { metric = "DatasetReadTime", dims = ",Dataset,Pass", stat = "p50" }
      rd_whole9 = { metric = "DatasetReadTime", dims = ",Dataset,Pass", stat = "p99" }
      rd_close9 = { metric = "DatasetReadCloseLatency", dims = ",Dataset,Pass", stat = "p99" }
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

  # ONTAP metrics come from the origin client, so they live in its region for both clusters.
  ontap_search = { for side in keys(var.sides) : side => {
    for k, m in {
      lat     = "OntapLatencyUs"
      iops    = "OntapIops"
      thr     = "OntapThroughputBytes"
      nfs_lat = "OntapNfsLatencyUs"
      } : k => format("SEARCH('{%s,Lab,Side,Cluster,Op,Volume} MetricName=\"%s\" Lab=\"%s\" Cluster=\"%s\"', 'Average', 60)",
    local.ns, m, local.lab, side)
  } }
  flexcache_search = { for k, m in { miss = "FlexCacheMissPercent", req = "FlexCacheRequestedBlocks", missb = "FlexCacheMissBlocks" } :
  k => format("SEARCH('{%s,Lab,Side,Cluster,Volume} MetricName=\"%s\" Lab=\"%s\" Cluster=\"cache\"', 'Average', 60)", local.ns, m, local.lab) }

  ontap_widgets = { for side in keys(var.sides) : side => var.ontap_region == null ? [] : concat([
    {
      title   = "ONTAP ${side} cluster: volume latency per operation type (µs)"
      region  = var.ontap_region
      metrics = [[{ id = "olat", expression = local.ontap_search[side].lat }]]
    },
    {
      title   = "ONTAP ${side} cluster: volume IOPS per operation type"
      region  = var.ontap_region
      metrics = [[{ id = "oiops", expression = local.ontap_search[side].iops }]]
    },
    {
      title   = "ONTAP ${side} cluster: NFS latency per NFS operation (µs)"
      region  = var.ontap_region
      metrics = [[{ id = "onfs", expression = local.ontap_search[side].nfs_lat }]]
    },
    ], side != "cache" ? [] : [
    {
      title  = "FlexCache: cache miss % and blocks per second requested / fetched from the origin"
      region = var.ontap_region
      metrics = [
        [{ id = "fmiss", expression = local.flexcache_search.miss, label = "miss %", yAxis = "right" }],
        [{ id = "freq", expression = local.flexcache_search.req }],
        [{ id = "fmb", expression = local.flexcache_search.missb }],
      ]
    },
    ], [
    {
      title  = "Latency between the FSx file systems (ms), measured by ONTAP: ${side} column, both directions"
      region = var.ontap_region
      metrics = [
        [{ id = "fs", expression = format("SEARCH('{%s,Lab,Side,From,Method,To} MetricName=\"FsPingMs\" Lab=\"%s\"', 'Average', 60)", local.ns, local.lab) }],
      ]
    },
    ], side != "origin" ? [] : [
    {
      title  = "Fallback: ICMP from the origin client to both clusters' intercluster IPs (ms)"
      region = var.ontap_region
      metrics = [
        [{ id = "ic", expression = format("SEARCH('{%s,Lab,Side,Cluster,Target} MetricName=\"InterclusterPingMs\" Lab=\"%s\"', 'Average', 60)", local.ns, local.lab) }],
      ]
    },
  ]) }

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
      title = "${side}: dataset read (MB/s) and files per minute, per pass"
      metrics = [
        [{ id = "rb", expression = local.bench[side].rd_bytes, visible = false }],
        [{ id = "rmbs", expression = "rb/60000000", label = "MB/s" }],
        [{ id = "rf", expression = local.bench[side].rd_files, label = "files/min", yAxis = "right" }],
      ]
    },
    {
      title = "${side}: dataset read latency per pass (µs): open, first byte, whole file, close"
      metrics = [
        [{ id = "ro5", expression = local.bench[side].rd_open50, label = "open p50" }],
        [{ id = "ro9", expression = local.bench[side].rd_open99, label = "open p99" }],
        [{ id = "rf5", expression = local.bench[side].rd_first, label = "first byte p50" }],
        [{ id = "rf9", expression = local.bench[side].rd_first9, label = "first byte p99" }],
        [{ id = "rw5", expression = local.bench[side].rd_whole, label = "whole file p50" }],
        [{ id = "rw9", expression = local.bench[side].rd_whole9, label = "whole file p99" }],
        [{ id = "rc9", expression = local.bench[side].rd_close9, label = "close p99" }],
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
      for i, w in concat(local.column[side], local.ontap_widgets[side]) : {
        type   = "metric"
        x      = local.col[side]
        y      = 3 + i * 6
        width  = 12
        height = 6
        properties = merge({
          title   = w.title
          region  = try(w.region, var.sides[side].region)
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
