# Layer 2 - FSx for ONTAP.
#   Origin FSxN: always.
#   Cache FSxN:  only when enable_cache_fsxn = true.
# Reads VPC/subnet IDs from the 01-landing-zone state.

data "terraform_remote_state" "lz" {
  backend = "local"
  config = {
    path = "${path.root}/../01-landing-zone/terraform.tfstate"
  }
}

locals {
  lz = data.terraform_remote_state.lz.outputs

  # Both sides accept traffic from both VPCs (intercluster over peering) and from
  # the bastion VPC (ONTAP REST API for stack 04), when a bastion is peered.
  allowed_cidrs = compact([
    local.lz.origin.vpc_cidr,
    local.lz.cache.vpc_cidr,
    try(local.lz.bastion.vpc_cidr, null),
  ])
}

module "fsxn_origin" {
  source    = "../../modules/fsxn"
  providers = { aws = aws.origin }

  name            = "${var.project}-origin"
  vpc_id          = local.lz.origin.vpc_id
  subnet_ids      = local.lz.origin.private_subnet_ids
  route_table_ids = local.lz.origin.private_route_table_ids
  allowed_cidrs   = local.allowed_cidrs

  deployment_type                 = var.origin_fsxn.deployment_type
  storage_capacity_gib            = var.origin_fsxn.storage_capacity_gib
  throughput_capacity_per_ha_pair = var.origin_fsxn.throughput_capacity_per_ha_pair
  ha_pairs                        = var.origin_fsxn.ha_pairs

  svm_name = "svm_origin"
  volumes = {
    (var.origin_volume.name) = {
      size_gib      = var.origin_volume.size_gib
      junction_path = var.origin_volume.junction_path
    }
  }
}

module "fsxn_cache" {
  count = var.enable_cache_fsxn ? 1 : 0

  source    = "../../modules/fsxn"
  providers = { aws = aws.cache }

  name            = "${var.project}-cache"
  vpc_id          = local.lz.cache.vpc_id
  subnet_ids      = local.lz.cache.private_subnet_ids
  route_table_ids = local.lz.cache.private_route_table_ids
  allowed_cidrs   = local.allowed_cidrs

  deployment_type                 = var.cache_fsxn.deployment_type
  storage_capacity_gib            = var.cache_fsxn.storage_capacity_gib
  throughput_capacity_per_ha_pair = var.cache_fsxn.throughput_capacity_per_ha_pair
  ha_pairs                        = var.cache_fsxn.ha_pairs

  svm_name = "svm_cache"
  volumes  = {} # the FlexCache volume is created by stacks/04-flexcache via the ONTAP API
}
