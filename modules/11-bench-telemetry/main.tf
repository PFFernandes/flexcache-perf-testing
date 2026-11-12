# Test bench telemetry: the OpenTelemetry Collector and bench-probe on the Linux clients.
# While a test runs, results are written to the client's LOCAL staging folder only
# (/var/lib/bench/staging): writing to the results volume during a test would load the file
# systems being measured. bench-results-sync copies them to the RESULTS VOLUME (vol_bench,
# modules/12-bench-results-volume) after each command, and once more when this is destroyed.
# No results go to S3.
#
#   1. stage    files/stage.sh on the OPERATOR MACHINE downloads the Collector RPM from
#               GitHub, checks its SHA-256 and copies it into the package bucket of each
#               region (stacks/00-bench-store): the clients have no internet, only the S3
#               gateway endpoint of their region.
#   2. access   each client role may read vendor/* in its region's package bucket. Nothing else.
#   3. install  files/install.sh sends files/remote.sh to each client with SSM Run Command:
#               mounts the results volume, creates the staging folder, installs the RPM,
#               validates and applies the config, starts otelcol-contrib and bench-probe, writes
#               labs/<lab>/lab.json on the volume, and waits until telemetry is being staged.
#
# Needs the bench on the clients first (modules/09-bench-deploy): bench-probe runs from
# /opt/bench. `terraform destroy` stops both services, copies everything staged to the results
# volume (and fails if it can't, so no results are lost), then removes the package and the
# mount. The data on the volume stays.

locals {
  buckets  = { for side, c in var.clients : c.bucket => c.bucket_region }
  packages = { for arch in var.collector_architectures : arch => var.collector_sha256[arch] }

  # Local while the Collector writes; bench-results-sync copies the same relative path to the volume.
  telemetry_rel   = { for side, c in var.clients : side => "telemetry/${var.lab}/${side}/${c.instance_id}/metrics.json" }
  telemetry_paths = { for side, rel in local.telemetry_rel : side => "${var.staging_dir}/${rel}" }
  results_paths   = { for side, rel in local.telemetry_rel : side => "${var.results.mount_point}/${rel}" }
  max_backups     = max(1, floor(var.local_buffer_mib / var.rotate_mib))

  resource_attributes = { for side, c in var.clients : side => {
    "bench.lab"      = var.lab
    "bench.side"     = side
    "host.id"        = c.instance_id
    "cloud.provider" = "aws"
    "cloud.region"   = c.region
  } }

  collector_config = { for side, c in var.clients : side => templatefile("${path.module}/files/collector.yaml.tftpl", {
    side                = side
    interval_s          = var.interval_s
    flush_s             = var.flush_s
    memory_limit_mib    = var.memory_limit_mib
    path                = local.telemetry_paths[side]
    rotate_mib          = var.rotate_mib
    max_backups         = local.max_backups
    resource_attributes = local.resource_attributes[side]
  }) }

  probe_config = { for side, c in var.clients : side => jsonencode({
    interval_s      = var.interval_s
    ping_interval_s = var.ping_interval_s
    otlp_endpoint   = "http://127.0.0.1:4318/v1/metrics"
    mount_prefixes  = ["/mnt/fsxn", "/mnt/bench"]
    ping_targets    = c.ping_targets
  }) }

  # bench-ontap runs on the origin client only (it may read the fsxadmin secret).
  ontap_side = var.ontap != null && contains(keys(var.clients), "origin") ? "origin" : null
  ontap_config = { for side, c in var.clients : side => side == local.ontap_side ? jsonencode({
    interval_s      = var.ontap.interval_s
    ping_interval_s = var.ontap.ping_interval_s
    otlp_endpoint   = "http://127.0.0.1:4318/v1/metrics"
    secret          = { arn = var.ontap.secret_arn, region = var.ontap.secret_region }
    clusters        = var.ontap.clusters
    peer_ping       = true
  }) : "{}" }

  lab_json = jsonencode(merge(var.lab_info, {
    lab = var.lab
    results_volume = {
      volume_id     = var.results.volume_id
      volume_name   = var.results.volume_name
      side          = var.results.side
      nfs_ip        = var.results.nfs_ip
      junction_path = var.results.junction_path
      mount_point   = var.results.mount_point
    }
    telemetry = {
      collector_version    = var.collector_version
      interval_s           = var.interval_s
      ping_interval_s      = var.ping_interval_s
      staged_while_running = local.telemetry_paths
      on_results_volume    = local.results_paths
    }
  }))

  settings = { for side, c in var.clients : side => join("\n", [
    "VERSION=${var.collector_version}",
    "SHA_AMD64=${lookup(local.packages, "amd64", "")}",
    "SHA_ARM64=${lookup(local.packages, "arm64", "")}",
    "BUCKET=${c.bucket}",
    "BUCKET_REGION=${c.bucket_region}",
    "LAB=${var.lab}",
    "SIDE=${side}",
    "INSTANCE_ID=${c.instance_id}",
    "RESULTS_SERVER=${var.results.nfs_ip}",
    "RESULTS_EXPORT=${var.results.junction_path}",
    "RESULTS_MOUNT=${var.results.mount_point}",
    "RESULTS_OPTIONS=${var.results.nfs_options}",
    "STAGING=${var.staging_dir}",
    "CLOUDWATCH_NAMESPACE=${coalesce(var.cloudwatch_namespace, "-")}",
    "CLOUDWATCH_REGION=${c.region}",
    "ONTAP=${side == local.ontap_side ? 1 : 0}",
    "FLUSH_S=${var.flush_s}",
    "",
  ]) }
}

# --- 1. package into the bucket(s) ------------------------------------------------------

resource "terraform_data" "stage" {
  triggers_replace = {
    version  = var.collector_version
    packages = jsonencode(local.packages)
    buckets  = jsonencode(local.buckets)
    script   = filesha256("${path.module}/files/stage.sh")
  }

  provisioner "local-exec" {
    command = "bash '${path.module}/files/stage.sh'"
    environment = {
      VERSION  = var.collector_version
      PACKAGES = join(" ", [for arch, sha in local.packages : "${arch}=${sha}"])
      BUCKETS  = join(" ", [for b, r in local.buckets : "${b}=${r}"])
    }
  }
}

# --- 2. the clients may only read the package -------------------------------------------

resource "aws_iam_role_policy" "read_packages" {
  for_each = var.clients

  name = "${var.name}-${each.key}-bench-read-packages"
  role = each.value.role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadVendorPackages"
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "${each.value.bucket_arn}/vendor/*"
    }]
  })
}

# --- 3. results mount + collector + probe on each client ---------------------------------

resource "terraform_data" "install" {
  for_each = var.clients

  triggers_replace = {
    instance_id = each.value.instance_id
    version     = var.collector_version
    settings    = sha256(local.settings[each.key])
    collector   = sha256(local.collector_config[each.key])
    probe       = sha256(local.probe_config[each.key])
    lab         = sha256(local.lab_json)
    ontap       = sha256(local.ontap_config[each.key])
    scripts     = sha256(join(",", [filesha256("${path.module}/files/install.sh"), filesha256("${path.module}/files/remote.sh")]))
  }

  input = {
    install_sh  = "${path.module}/files/install.sh"
    remote_sh   = "${path.module}/files/remote.sh"
    region      = each.value.region
    instance_id = each.value.instance_id
    side        = each.key
  }

  provisioner "local-exec" {
    command = "bash '${self.input.install_sh}'"
    environment = {
      ACTION        = "install"
      REGION        = self.input.region
      INSTANCE_ID   = self.input.instance_id
      SIDE          = self.input.side
      REMOTE_SH     = self.input.remote_sh
      SETTINGS_B64  = base64encode(local.settings[each.key])
      COLLECTOR_B64 = base64encode(local.collector_config[each.key])
      PROBE_B64     = base64encode(local.probe_config[each.key])
      LAB_B64       = base64encode(local.lab_json)
      ONTAP_B64     = base64encode(local.ontap_config[each.key])
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${self.input.install_sh}'"
    environment = {
      ACTION      = "remove"
      REGION      = self.input.region
      INSTANCE_ID = self.input.instance_id
      SIDE        = self.input.side
      REMOTE_SH   = self.input.remote_sh
    }
  }

  # The client needs the package in S3 and the permission while this runs, also on destroy.
  depends_on = [terraform_data.stage, aws_iam_role_policy.read_packages]
}
