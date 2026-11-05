# Layer 4 - ONTAP configuration: cluster peering + SVM peering + FlexCache volume.
# Requires both FSxN file systems from 02-fsxn (enable_cache_fsxn = true).

data "terraform_remote_state" "fsxn" {
  backend = "local"
  config = {
    path = "${path.root}/../02-fsxn/terraform.tfstate"
  }
}

locals {
  origin = data.terraform_remote_state.fsxn.outputs.origin
  cache  = try(data.terraform_remote_state.fsxn.outputs.cache, null)

  # Same fsxadmin credentials for both FSx for ONTAP (one shared secret from 02-fsxn).
  fsxadmin = jsondecode(data.aws_secretsmanager_secret_version.fsxadmin.secret_string)
}

# The shared secret lives in the origin region, so it is read through aws.origin.
data "aws_secretsmanager_secret_version" "fsxadmin" {
  provider  = aws.origin
  secret_id = data.terraform_remote_state.fsxn.outputs.fsxadmin_secret.arn

  lifecycle {
    precondition {
      condition     = local.cache != null
      error_message = "No FSx for ONTAP Cache in the 02-fsxn state. Set enable_cache_fsxn = true in stacks/02-fsxn, apply it, then run this stack."
    }
  }
}

module "flexcache" {
  source = "../../modules/07-ontap-flexcache"

  origin_cx_profile = "origin"
  cache_cx_profile  = "cache"

  origin_intercluster_ips = local.origin.intercluster_ips
  cache_intercluster_ips  = try(local.cache.intercluster_ips, [])

  origin_svm_name    = local.origin.svm_name
  cache_svm_name     = try(local.cache.svm_name, "")
  origin_volume_name = local.origin.volume_name

  flexcache_name          = var.flexcache_name
  flexcache_size_gib      = var.flexcache_size_gib
  flexcache_junction_path = var.flexcache_junction_path
  aggregates              = var.cache_aggregates
}
