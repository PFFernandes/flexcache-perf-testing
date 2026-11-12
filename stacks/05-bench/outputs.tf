output "bench" {
  description = "null until the bench is deployed."
  value = length(module.bench) == 0 ? null : {
    bench_home    = module.bench[0].bench_home
    bundle_sha256 = module.bench[0].bundle_sha256
    files         = module.bench[0].file_count
    clients = {
      for side, id in module.bench[0].deployed_to : side => {
        instance_id = id
        login       = "aws ssm start-session --target ${id} --region ${local.clients[side].region}"
        first_test = (side == "origin"
          ? "bench-dataset create --target /mnt/fsxn/vol_origin --spec smoke"
        : "bench-dataset plan --spec smoke")
      }
    }
  }
}

output "results" {
  description = "The results volume (vol_bench) and what's on it. null when telemetry = false or not deployed."
  value = local.results == null || length(module.telemetry) == 0 ? null : {
    volume_id       = local.results.volume_id
    file_system     = "${var.results_volume.side} (${local.results_fs.file_system_id})"
    nfs             = "${local.results.nfs_ip}:${local.results.junction_path}"
    mount_point     = module.telemetry[0].results_mount
    telemetry_files = module.telemetry[0].telemetry_files
    datasets        = "${module.telemetry[0].results_mount}/datasets/"
    lab_json        = "${module.telemetry[0].results_mount}/labs/${local.lab}/lab.json"
    final_backups   = "aws fsx describe-backups --region ${local.results_fs.region} --filters Name=volume-id,Values=${local.results.volume_id}"
  }
}

output "telemetry" {
  description = "null when telemetry = false or not deployed."
  value = length(module.telemetry) == 0 ? null : {
    collector_version = module.telemetry[0].collector_version
    ontap_poller      = module.telemetry[0].ontap_poller == null ? "off (needs ontap_metrics = true and 04-flexcache)" : "on the ${module.telemetry[0].ontap_poller} client, watching ${jsonencode({ for k, c in local.ontap.clusters : k => c.volumes })}"
    check_on_client   = "systemctl status otelcol-contrib bench-probe bench-ontap"
  }
}

output "dashboard" {
  description = "The lab's CloudWatch dashboard. null when cloudwatch = false or not deployed."
  value = length(module.dashboard) == 0 ? null : {
    name = module.dashboard[0].dashboard_name
    url  = module.dashboard[0].url
    note = "Bench metrics appear after each test (bench-results-sync); FSx and EC2 metrics live."
  }
}
