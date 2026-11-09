# Layer 3 - Linux test clients (Amazon Linux 2023), one per side:
#   Origin client: origin VPC, same subnet as the FSx for ONTAP Origin.
#                  Mounts only the Origin: vol_origin -> /mnt/fsxn/vol_origin.
#   Cache client:  cache VPC, same subnet as the FSx for ONTAP Cache.
#                  Mounts only the Cache: vol_cache (FlexCache) -> /mnt/fsxn/vol_cache.
#                  cache_mounts_origin = true adds vol_origin over the peering as a baseline.
# Each client is switched on with deploy_<side> (common.tfvars) AND <side>_ec2.
# Reads the networks from 01-landing-zone and the NFS endpoints from 02-fsxn.

data "terraform_remote_state" "lz" {
  backend = "local"
  config = {
    path = "${path.root}/../01-landing-zone/terraform.tfstate"
  }
}

data "terraform_remote_state" "fsxn" {
  backend = "local"
  config = {
    path = "${path.root}/../02-fsxn/terraform.tfstate"
  }
}

locals {
  lz          = data.terraform_remote_state.lz.outputs
  fsxn_origin = try(data.terraform_remote_state.fsxn.outputs.origin, null)
  fsxn_cache  = try(data.terraform_remote_state.fsxn.outputs.cache, null)

  want_origin = var.deploy_origin && var.origin_ec2
  want_cache  = var.deploy_cache && var.cache_ec2

  has_origin = try(local.lz.origin, null) != null && local.fsxn_origin != null
  has_cache  = try(local.lz.cache, null) != null && local.fsxn_cache != null

  mount_opts = var.nfs_options == null ? {} : { options = var.nfs_options }

  origin_mounts = local.fsxn_origin == null ? {} : {
    vol_origin = merge({ server = local.fsxn_origin.svm_nfs_ip, export = local.fsxn_origin.junction_path }, local.mount_opts)
  }

  cache_mounts = merge(
    local.fsxn_cache == null ? {} : {
      vol_cache = merge({ server = local.fsxn_cache.svm_nfs_ip, export = var.flexcache_junction_path }, local.mount_opts)
    },
    var.cache_mounts_origin ? local.origin_mounts : {},
  )
}

# Clear error when a client is wanted but its network or FSx for ONTAP isn't deployed.
resource "terraform_data" "prerequisites" {
  lifecycle {
    precondition {
      condition     = !local.want_origin || local.has_origin
      error_message = "Origin client wanted, but the Network Origin (01-landing-zone) or FSx for ONTAP Origin (02-fsxn) is missing. Apply those first, or set origin_ec2 = false."
    }
    precondition {
      condition     = !local.want_cache || local.has_cache
      error_message = "Cache client wanted, but the Network Cache (01-landing-zone) or FSx for ONTAP Cache (02-fsxn) is missing. Apply those first, or set cache_ec2 = false."
    }
  }
}

# --- Origin client -------------------------------------------------------------
module "ec2_origin" {
  count = local.want_origin && local.has_origin ? 1 : 0

  source    = "../../modules/06-ec2-client"
  providers = { aws = aws.origin }

  name          = "${local.name_prefix}-origin-client"
  instance_name = "${var.creator}-origin-client"
  hostname      = "origin"
  vpc_id        = local.lz.origin.vpc_id
  subnet_id     = local.lz.origin.private_subnet_ids[0] # same subnet as the FSx for ONTAP Origin
  instance_type = var.instance_type
  architecture  = var.architecture
  enable_eice   = var.enable_eice
  enable_ssm    = var.enable_ssm
  nfs_mounts    = local.origin_mounts
}

# --- Cache client ----------------------------------------------------------------
module "ec2_cache" {
  count = local.want_cache && local.has_cache ? 1 : 0

  source    = "../../modules/06-ec2-client"
  providers = { aws = aws.cache }

  name          = "${local.name_prefix}-cache-client"
  instance_name = "${var.creator}-cache-client"
  hostname      = "cache"
  vpc_id        = local.lz.cache.vpc_id
  subnet_id     = local.lz.cache.private_subnet_ids[0] # same subnet as the FSx for ONTAP Cache
  instance_type = var.instance_type
  architecture  = var.architecture
  enable_eice   = var.enable_eice
  enable_ssm    = var.enable_ssm
  nfs_mounts    = local.cache_mounts
}
