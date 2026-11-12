# Layer 5 - Test bench on the Linux EC2 clients of stacks/03-ec2. Optional: stacks 01-04
# are a complete lab without it.
#
#   bench      modules/09-bench-deploy     the bench code in /opt/bench and the commands
#                                          bench-dataset and bench-datasets-nfs
#   results    modules/12-bench-results-volume   vol_bench on the origin (or cache) FSx for
#   (telemetry = true)                           ONTAP; FSx takes a final backup when it's deleted
#   telemetry  modules/11-bench-telemetry        mounts vol_bench on both clients; OpenTelemetry
#                                                Collector + bench-probe write to it, and so do the
#                                                dataset records. Nothing goes to S3.
#
#   ontap      (ontap_metrics = true, needs 04)   bench-ontap on the origin client: ONTAP volume, NFS and
#                                                FlexCache counters of both clusters, with fsxadmin
#   cloudwatch modules/13-bench-cloudwatch        CloudWatch endpoint + PutMetricData per client VPC;
#   (cloudwatch = true)                          bench-results-sync pushes each test's metrics AFTER it
#              modules/14-bench-dashboard        one dashboard: bench + FSx + EC2 metrics, both sides
#
# Needs: the clients with SSM (03-ec2) on protocol = "nfs"; for telemetry also the file systems
# (02-fsxn) and the package bucket (00-bench-store), which only delivers the Collector package
# (the clients have no internet). FlexCache (04) is not required, but the cache client's
# /mnt/fsxn/vol_cache only mounts once it exists.
#
# Teardown: destroy this stack BEFORE 03-ec2 and 02-fsxn. Deleting vol_bench triggers its final
# backup, which outlives the lab.

data "terraform_remote_state" "ec2" {
  backend = "local"
  config = {
    path = "${path.root}/../03-ec2/terraform.tfstate"
  }
}

data "terraform_remote_state" "fsxn" {
  count   = var.telemetry ? 1 : 0
  backend = "local"
  config = {
    path = "${path.root}/../02-fsxn/terraform.tfstate"
  }
}

data "terraform_remote_state" "lz" {
  count   = var.telemetry && var.cloudwatch ? 1 : 0
  backend = "local"
  config = {
    path = "${path.root}/../01-landing-zone/terraform.tfstate"
  }
}

# Optional: without stack 04 (no FlexCache yet) the ONTAP poller is just off.
data "terraform_remote_state" "flexcache" {
  count   = var.telemetry && var.ontap_metrics && fileexists("${path.root}/../04-flexcache/terraform.tfstate") ? 1 : 0
  backend = "local"
  config = {
    path = "${path.root}/../04-flexcache/terraform.tfstate"
  }
}

data "terraform_remote_state" "store" {
  count   = var.telemetry ? 1 : 0
  backend = "local"
  config = {
    path = "${path.root}/../00-bench-store/terraform.tfstate"
  }
}

locals {
  lab = local.name_prefix

  available = {
    origin = try(data.terraform_remote_state.ec2.outputs.origin_client, null)
    cache  = try(data.terraform_remote_state.ec2.outputs.cache_client, null)
  }

  clients = {
    for side in var.bench_clients : side => {
      region      = local.available[side].region
      instance_id = local.available[side].instance_id
    }
    if local.available[side] != null
  }

  not_linux = [for side, c in local.available : side if c != null && try(c.os, "linux") != "linux"]
  no_ssm    = [for side in keys(local.clients) : side if !try(local.available[side].ssm_enabled, false)]
  ready     = var.protocol == "nfs" && length(local.not_linux) == 0 && length(local.no_ssm) == 0 && length(local.clients) > 0

  # --- telemetry inputs ---
  fsx = {
    origin = try(data.terraform_remote_state.fsxn[0].outputs.origin, null)
    cache  = try(data.terraform_remote_state.fsxn[0].outputs.cache, null)
  }
  buckets    = try(data.terraform_remote_state.store[0].outputs.buckets, null)
  results_fs = local.fsx[var.results_volume.side]

  # Every client pings the NFS IP of both file systems: its own (local latency) and the
  # other one (latency across the peering, the cross-region distance).
  ping_targets = merge(
    local.fsx.origin != null ? { "origin-nfs" = local.fsx.origin.svm_nfs_ip } : {},
    local.fsx.cache != null ? { "cache-nfs" = local.fsx.cache.svm_nfs_ip } : {},
  )

  telemetry_clients = local.buckets == null ? {} : {
    for side, c in local.clients : side => {
      region        = c.region
      instance_id   = c.instance_id
      role_name     = local.available[side].role_name
      bucket        = local.buckets[side].bucket
      bucket_arn    = local.buckets[side].arn
      bucket_region = local.buckets[side].region
      ping_targets  = local.ping_targets
    }
  }

  lab_info = {
    regions      = { origin = var.origin_region, cache = var.cache_region }
    cross_region = var.origin_region != var.cache_region
    file_systems = { for side, f in local.fsx : side => {
      file_system_id = f.file_system_id
      region         = f.region
      svm_name       = f.svm_name
      svm_nfs_ip     = f.svm_nfs_ip
    } if f != null }
    clients = { for side, c in local.clients : side => {
      instance_id = c.instance_id
      region      = c.region
      mounts      = try(local.available[side].mounts, {})
    } }
  }

  networks = {
    origin = try(data.terraform_remote_state.lz[0].outputs.origin, null)
    cache  = try(data.terraform_remote_state.lz[0].outputs.cache, null)
  }
  cloudwatch_on = local.ready && var.telemetry && var.cloudwatch && local.buckets != null && local.results_fs != null

  # bench-ontap: needs the origin client and stack 04 (its Secrets Manager endpoint and the
  # permission to read the fsxadmin secret on the origin client's role).
  flexcache_out = try(data.terraform_remote_state.flexcache[0].outputs.flexcache, null)
  fsxadmin      = try(data.terraform_remote_state.fsxn[0].outputs.fsxadmin_secret, null)
  ontap_on      = var.telemetry && var.ontap_metrics && local.flexcache_out != null && local.fsxadmin != null && contains(keys(local.clients), "origin")
  ontap = !local.ontap_on ? null : {
    secret_arn    = local.fsxadmin.arn
    secret_region = local.fsxadmin.region
    clusters = { for side, f in local.fsx : side => {
      mgmt_ip          = f.management_ip
      intercluster_ips = f.intercluster_ips
      volumes = compact(concat(
        side == "origin" ? [f.volume_name] : [local.flexcache_out.name],
        var.results_volume.side == side ? [var.results_volume.name] : [],
      ))
    } if f != null }
  }
  cloudwatch_namespace = "FlexCacheBench"

  results_vol = var.telemetry ? one(concat(module.results_origin, module.results_cache)) : null
  results = local.results_vol == null ? null : {
    volume_id     = local.results_vol.volume_id
    volume_name   = local.results_vol.volume_name
    side          = var.results_volume.side
    nfs_ip        = local.results_fs.svm_nfs_ip
    junction_path = local.results_vol.junction_path
    mount_point   = "/mnt/fsxn/${var.results_volume.name}"
  }
}

resource "terraform_data" "prerequisites" {
  lifecycle {
    precondition {
      condition     = var.protocol == "nfs"
      error_message = "The test bench runs on the Linux NFS clients. With protocol = \"smb\" the clients are Windows; set protocol = \"nfs\" to use the bench."
    }
    precondition {
      condition     = length(local.not_linux) == 0
      error_message = "These clients in the 03-ec2 state are not Linux: ${join(", ", local.not_linux)}. Re-apply 03-ec2 with protocol = \"nfs\"."
    }
    precondition {
      condition     = length(local.clients) > 0
      error_message = "None of bench_clients (${join(", ", var.bench_clients)}) is in the 03-ec2 state. Apply 03-ec2 first."
    }
    precondition {
      condition     = length(local.no_ssm) == 0
      error_message = "These clients have no SSM (enable_ssm = true in stacks/03-ec2), which the bench is sent through: ${join(", ", local.no_ssm)}."
    }
    precondition {
      condition     = !var.telemetry || local.buckets != null
      error_message = "telemetry = true needs the package bucket that delivers the Collector to the clients: apply stacks/00-bench-store first (once per account), or set telemetry = false."
    }
    precondition {
      condition     = !var.telemetry || local.results_fs != null
      error_message = "results_volume.side = \"${var.results_volume.side}\", but that file system is not in the 02-fsxn state. Deploy it or choose the other side."
    }
    precondition {
      condition     = !var.telemetry || local.fsx.origin != null || local.fsx.cache != null
      error_message = "telemetry = true needs the file systems in the 02-fsxn state (for the lab description and ping targets). Apply 02-fsxn first."
    }
  }
}

module "bench" {
  count  = local.ready ? 1 : 0
  source = "../../modules/09-bench-deploy"

  clients          = local.clients
  source_root      = abspath("${path.root}/../..")
  install_packages = var.install_packages
  run_tests        = var.run_tests

  depends_on = [terraform_data.prerequisites]
}

# vol_bench lives on one file system; the module runs in that file system's region.
module "results_origin" {
  count  = local.ready && var.telemetry && var.results_volume.side == "origin" && local.fsx.origin != null ? 1 : 0
  source = "../../modules/12-bench-results-volume"

  providers = { aws = aws.origin }

  name           = "${local.name_prefix}-${var.results_volume.name}"
  lab            = local.lab
  file_system_id = local.fsx.origin.file_system_id
  volume_name    = var.results_volume.name
  junction_path  = "/${var.results_volume.name}"
  size_gib       = var.results_volume.size_gib

  depends_on = [terraform_data.prerequisites]
}

module "results_cache" {
  count  = local.ready && var.telemetry && var.results_volume.side == "cache" && local.fsx.cache != null ? 1 : 0
  source = "../../modules/12-bench-results-volume"

  providers = { aws = aws.cache }

  name           = "${local.name_prefix}-${var.results_volume.name}"
  lab            = local.lab
  file_system_id = local.fsx.cache.file_system_id
  volume_name    = var.results_volume.name
  junction_path  = "/${var.results_volume.name}"
  size_gib       = var.results_volume.size_gib

  depends_on = [terraform_data.prerequisites]
}

# CloudWatch endpoint + permission in each client's VPC, so the client can push after each test.
module "cloudwatch_origin" {
  count  = local.cloudwatch_on && contains(keys(local.clients), "origin") && local.networks.origin != null ? 1 : 0
  source = "../../modules/13-bench-cloudwatch"

  providers = { aws = aws.origin }

  name             = "${local.name_prefix}-origin-bench"
  vpc_id           = local.networks.origin.vpc_id
  vpc_cidr         = local.networks.origin.vpc_cidr
  subnet_id        = local.networks.origin.private_subnet_ids[0]
  client_role_name = local.available.origin.role_name
  namespace        = local.cloudwatch_namespace
}

module "cloudwatch_cache" {
  count  = local.cloudwatch_on && contains(keys(local.clients), "cache") && local.networks.cache != null ? 1 : 0
  source = "../../modules/13-bench-cloudwatch"

  providers = { aws = aws.cache }

  name             = "${local.name_prefix}-cache-bench"
  vpc_id           = local.networks.cache.vpc_id
  vpc_cidr         = local.networks.cache.vpc_cidr
  subnet_id        = local.networks.cache.private_subnet_ids[0]
  client_role_name = local.available.cache.role_name
  namespace        = local.cloudwatch_namespace
}

module "dashboard" {
  count  = local.cloudwatch_on ? 1 : 0
  source = "../../modules/14-bench-dashboard"

  providers = { aws = aws.origin }

  dashboard_name = "${local.name_prefix}-bench"
  lab            = local.lab
  namespace      = local.cloudwatch_namespace
  sides = { for side in ["origin", "cache"] : side => {
    region         = side == "origin" ? var.origin_region : var.cache_region
    file_system_id = try(local.fsx[side].file_system_id, null)
    instance_id    = try(local.clients[side].instance_id, null)
  } if local.fsx[side] != null || contains(keys(local.clients), side) }
  results_volume_id = try(local.results.volume_id, null)
  ontap_region      = local.ontap_on ? var.origin_region : null
}

module "telemetry" {
  count  = local.ready && var.telemetry && local.buckets != null && local.results_fs != null ? 1 : 0
  source = "../../modules/11-bench-telemetry"

  providers = { aws = aws.origin }

  name                 = local.name_prefix
  lab                  = local.lab
  clients              = local.telemetry_clients
  results              = local.results
  lab_info             = local.lab_info
  cloudwatch_namespace = local.cloudwatch_on ? local.cloudwatch_namespace : null
  ontap                = local.ontap

  collector_version       = var.collector_version
  collector_sha256        = var.collector_sha256
  collector_architectures = var.collector_architectures
  interval_s              = var.telemetry_interval_s
  ping_interval_s         = var.ping_interval_s

  # bench-probe runs from /opt/bench, so the bench goes first. The CloudWatch endpoint and
  # permission must exist while it runs, also on destroy (the final copy pushes too).
  depends_on = [module.bench, module.cloudwatch_origin, module.cloudwatch_cache]
}
