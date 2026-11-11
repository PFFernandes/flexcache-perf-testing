# Layer 2 - FSx for ONTAP.
#   FSx for ONTAP Origin (modules/05-fsxn-origin): when deploy_origin = true.
#   FSx for ONTAP Cache  (modules/06-fsxn-cache):  when deploy_cache  = true.
# protocol = "smb" (common.tfvars): both SVMs join the Managed AD of 01-landing-zone,
# security style NTFS and port 445 open. Default nfs: UNIX security, NFS only.
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
  # peering, NFS clients and the ONTAP REST API (stack 04-flexcache).
  has_origin_network = try(local.lz.origin, null) != null
  has_cache_network  = try(local.lz.cache, null) != null

  allowed_cidrs = compact([
    try(local.lz.origin.vpc_cidr, null),
    try(local.lz.cache.vpc_cidr, null),
  ])

  # protocol = "smb": both SVMs join the Managed AD from 01-landing-zone.
  smb       = var.protocol == "smb"
  directory = try(local.lz.directory, null)
  ad_ready  = local.smb && local.directory != null
  active_directory = {
    for side, netbios in var.svm_netbios_names : side => local.ad_ready ? {
      netbios_name = netbios
      domain_name  = local.directory.domain_name
      dns_ips      = local.directory.dns_ips
      username     = "Admin"
      ou           = local.directory.computers_ou
      admins_group = local.directory.fsx_admins_group
    } : null
  }
}

# The Admin password of the Managed AD, from its secret (origin region).
data "aws_secretsmanager_secret_version" "ad_admin" {
  count    = local.ad_ready ? 1 : 0
  provider = aws.origin

  secret_id = local.directory.admin_secret.arn
}

locals {
  ad_password = local.ad_ready ? jsondecode(data.aws_secretsmanager_secret_version.ad_admin[0].secret_string).password : null
}

# Clear error if a side is switched on here but its network is not in the
# 01-landing-zone state yet (apply 01-landing-zone first).
resource "terraform_data" "landing_zone_check" {
  lifecycle {
    precondition {
      condition     = !var.deploy_origin || local.has_origin_network
      error_message = "deploy_origin = true but there is no Network Origin in the 01-landing-zone state. Run ./tf.sh 01-landing-zone apply first."
    }
    precondition {
      condition     = !var.deploy_cache || local.has_cache_network
      error_message = "deploy_cache = true but there is no Network Cache in the 01-landing-zone state. Run ./tf.sh 01-landing-zone apply first."
    }
    precondition {
      condition     = !local.smb || local.directory != null
      error_message = "protocol = \"smb\" but there is no Managed AD in the 01-landing-zone state. Run ./tf.sh 01-landing-zone apply with the same common.tfvars first."
    }
  }
}

# --- FSx for ONTAP Origin ----------------------------------------------------
module "fsxn_origin" {
  # Skipped when the origin network is missing; terraform_data.landing_zone_check then explains why.
  count = var.deploy_origin && local.has_origin_network && (!local.smb || local.ad_ready) ? 1 : 0

  source    = "../../modules/05-fsxn-origin"
  providers = { aws = aws.origin }

  name            = "${local.name_prefix}-origin"
  vpc_id          = local.lz.origin.vpc_id
  subnet_ids      = local.lz.origin.private_subnet_ids
  route_table_ids = local.lz.origin.private_route_table_ids
  allowed_cidrs   = local.allowed_cidrs

  deployment_type                 = var.origin_fsxn.deployment_type
  storage_capacity_gib            = var.origin_fsxn.storage_capacity_gib
  throughput_capacity_per_ha_pair = var.origin_fsxn.throughput_capacity_per_ha_pair
  ha_pairs                        = var.origin_fsxn.ha_pairs

  fsxadmin_password = random_password.fsxadmin.result # same password as the Cache (credentials.tf)

  protocol         = var.protocol
  active_directory = local.active_directory["origin"]
  ad_password      = local.ad_password

  svm_name = "svm-origin"
  volumes = {
    (var.origin_volume.name) = {
      size_gib                   = var.origin_volume.size_gib
      junction_path              = var.origin_volume.junction_path
      volume_style               = var.origin_volume.volume_style
      constituents_per_aggregate = var.origin_volume.constituents_per_aggregate
      storage_efficiency_enabled = var.origin_volume.storage_efficiency_enabled
      security_style             = local.smb ? "NTFS" : "UNIX"
    }
  }
}

# --- FSx for ONTAP Cache -----------------------------------------------------
module "fsxn_cache" {
  # Skipped when the cache network is missing; terraform_data.landing_zone_check then explains why.
  count = var.deploy_cache && local.has_cache_network && (!local.smb || local.ad_ready) ? 1 : 0

  source    = "../../modules/06-fsxn-cache"
  providers = { aws = aws.cache }

  name            = "${local.name_prefix}-cache"
  vpc_id          = local.lz.cache.vpc_id
  subnet_ids      = local.lz.cache.private_subnet_ids
  route_table_ids = local.lz.cache.private_route_table_ids
  allowed_cidrs   = local.allowed_cidrs

  deployment_type                 = var.cache_fsxn.deployment_type
  storage_capacity_gib            = var.cache_fsxn.storage_capacity_gib
  throughput_capacity_per_ha_pair = var.cache_fsxn.throughput_capacity_per_ha_pair
  ha_pairs                        = var.cache_fsxn.ha_pairs

  fsxadmin_password = random_password.fsxadmin.result # same password as the Origin (credentials.tf)

  protocol         = var.protocol
  active_directory = local.active_directory["cache"]
  ad_password      = local.ad_password

  svm_name = "svm-cache"
  # No volumes: the FlexCache volume is created by stacks/04-flexcache via the ONTAP API.
}

# fsxn_origin got a count (deploy_origin); keep an already-applied Origin in place.
moved {
  from = module.fsxn_origin
  to   = module.fsxn_origin[0]
}
