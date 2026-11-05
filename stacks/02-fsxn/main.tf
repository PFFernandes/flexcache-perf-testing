# Layer 2 - FSx for ONTAP.
#   FSx for ONTAP Origin (modules/04-fsxn-origin): when deploy_origin = true.
#   FSx for ONTAP Cache  (modules/05-fsxn-cache):  when deploy_cache  = true.
# Same switches as 01-landing-zone (common.tfvars); that side's network must exist.
# Reads VPC/subnet IDs from the 01-landing-zone state.

data "terraform_remote_state" "lz" {
  backend = "local"
  config = {
    path = "${path.root}/../01-landing-zone/terraform.tfstate"
  }
}

locals {
  lz = data.terraform_remote_state.lz.outputs

  # Both sides accept traffic from both VPCs: intercluster/FlexCache over the
  # peering, NFS from the clients, and the ONTAP REST API that stack 04 reaches
  # from your Mac through an SSM tunnel on the origin EC2 client.
  allowed_cidrs = compact([
    try(local.lz.origin.vpc_cidr, null),
    try(local.lz.cache.vpc_cidr, null),
  ])
}

# Clear error if a side is switched on here but its network is not in the
# 01-landing-zone state yet (apply 01-landing-zone first).
resource "terraform_data" "landing_zone_check" {
  lifecycle {
    precondition {
      condition     = !var.deploy_origin || try(local.lz.origin, null) != null
      error_message = "deploy_origin = true but there is no Network Origin in the 01-landing-zone state. Run ./tf.sh 01-landing-zone apply first."
    }
    precondition {
      condition     = !var.deploy_cache || try(local.lz.cache, null) != null
      error_message = "deploy_cache = true but there is no Network Cache in the 01-landing-zone state. Run ./tf.sh 01-landing-zone apply first."
    }
  }
}

# --- FSx for ONTAP Origin ----------------------------------------------------
module "fsxn_origin" {
  count = var.deploy_origin ? 1 : 0

  source    = "../../modules/04-fsxn-origin"
  providers = { aws = aws.origin }

  name            = "${local.name_prefix}-origin"
  vpc_id          = try(local.lz.origin.vpc_id, null)
  subnet_ids      = try(local.lz.origin.private_subnet_ids, [])
  route_table_ids = try(local.lz.origin.private_route_table_ids, [])
  allowed_cidrs   = local.allowed_cidrs

  deployment_type                 = var.origin_fsxn.deployment_type
  storage_capacity_gib            = var.origin_fsxn.storage_capacity_gib
  throughput_capacity_per_ha_pair = var.origin_fsxn.throughput_capacity_per_ha_pair
  ha_pairs                        = var.origin_fsxn.ha_pairs

  fsxadmin_password = random_password.fsxadmin.result # same password as the Cache (credentials.tf)

  svm_name = "svm_origin"
  volumes = {
    (var.origin_volume.name) = {
      size_gib      = var.origin_volume.size_gib
      junction_path = var.origin_volume.junction_path
    }
  }
}

# --- FSx for ONTAP Cache -----------------------------------------------------
module "fsxn_cache" {
  count = var.deploy_cache ? 1 : 0

  source    = "../../modules/05-fsxn-cache"
  providers = { aws = aws.cache }

  name            = "${local.name_prefix}-cache"
  vpc_id          = try(local.lz.cache.vpc_id, null)
  subnet_ids      = try(local.lz.cache.private_subnet_ids, [])
  route_table_ids = try(local.lz.cache.private_route_table_ids, [])
  allowed_cidrs   = local.allowed_cidrs

  deployment_type                 = var.cache_fsxn.deployment_type
  storage_capacity_gib            = var.cache_fsxn.storage_capacity_gib
  throughput_capacity_per_ha_pair = var.cache_fsxn.throughput_capacity_per_ha_pair
  ha_pairs                        = var.cache_fsxn.ha_pairs

  fsxadmin_password = random_password.fsxadmin.result # same password as the Origin (credentials.tf)

  svm_name = "svm_cache"
  # No volumes: the FlexCache volume is created by stacks/04-flexcache via the ONTAP API.
}

# fsxn_origin got a count (deploy_origin); keep an already-applied Origin in place.
moved {
  from = module.fsxn_origin
  to   = module.fsxn_origin[0]
}
