# Layer 1 - landing zone:
#   Network Origin (origin VPC)  when deploy_origin = true
#   Network Cache  (cache VPC)   when deploy_cache  = true
#   VPC peering between them     only when both are deployed
# deploy_origin / deploy_cache come from common.tfvars and drive 02-fsxn too.

# --- Availability Zones and subnets ------------------------------------------
# AZs come from common.tfvars as letters (default ["a"] = <region>a). Unless the
# CIDRs are set explicitly, each AZ gets one private /24 (x.x.1.0, x.x.2.0, ...)
# and the first AZ gets one public /24 (x.x.101.0) only when NAT is enabled.

locals {
  origin_azs = [for s in var.origin_azs : "${var.origin_region}${s}"]
  cache_azs  = [for s in var.cache_azs : "${var.cache_region}${s}"]

  origin_private_subnet_cidrs = (var.origin_private_subnet_cidrs != null ? var.origin_private_subnet_cidrs
  : [for i in range(length(local.origin_azs)) : cidrsubnet(var.origin_vpc_cidr, 8, 1 + i)])
  cache_private_subnet_cidrs = (var.cache_private_subnet_cidrs != null ? var.cache_private_subnet_cidrs
  : [for i in range(length(local.cache_azs)) : cidrsubnet(var.cache_vpc_cidr, 8, 1 + i)])

  origin_public_subnet_cidrs = (var.origin_public_subnet_cidrs != null ? var.origin_public_subnet_cidrs
  : var.origin_nat_gateway ? [cidrsubnet(var.origin_vpc_cidr, 8, 101)] : [])
  cache_public_subnet_cidrs = (var.cache_public_subnet_cidrs != null ? var.cache_public_subnet_cidrs
  : var.cache_nat_gateway ? [cidrsubnet(var.cache_vpc_cidr, 8, 101)] : [])
}

# --- Network Origin ----------------------------------------------------------
module "origin_network" {
  count = var.deploy_origin ? 1 : 0

  source    = "../../modules/01-network-origin"
  providers = { aws = aws.origin }

  name                 = "${local.name_prefix}-origin"
  azs                  = local.origin_azs
  cidr_block           = var.origin_vpc_cidr
  private_subnet_cidrs = local.origin_private_subnet_cidrs
  public_subnet_cidrs  = local.origin_public_subnet_cidrs
  enable_nat_gateway   = var.origin_nat_gateway
}

# --- Network Cache -----------------------------------------------------------
module "cache_network" {
  count = var.deploy_cache ? 1 : 0

  source    = "../../modules/02-network-cache"
  providers = { aws = aws.cache }

  name                 = "${local.name_prefix}-cache"
  azs                  = local.cache_azs
  cidr_block           = var.cache_vpc_cidr
  private_subnet_cidrs = local.cache_private_subnet_cidrs
  public_subnet_cidrs  = local.cache_public_subnet_cidrs
  enable_nat_gateway   = var.cache_nat_gateway
}

# --- Peering (Origin <-> Cache) ---------------------------------------------
module "peering" {
  count = var.deploy_origin && var.deploy_cache ? 1 : 0

  source = "../../modules/03-vpc-peering"
  providers = {
    aws.requester = aws.origin
    aws.accepter  = aws.cache
  }

  name = "${local.name_prefix}-origin-to-cache"

  requester_vpc_id          = module.origin_network[0].vpc_id
  requester_cidr            = module.origin_network[0].vpc_cidr
  requester_route_table_ids = concat(module.origin_network[0].private_route_table_ids, module.origin_network[0].public_route_table_ids)

  accepter_vpc_id          = module.cache_network[0].vpc_id
  accepter_cidr            = module.cache_network[0].vpc_cidr
  accepter_route_table_ids = concat(module.cache_network[0].private_route_table_ids, module.cache_network[0].public_route_table_ids)
}

# --- State moves -------------------------------------------------------------
# These modules got a count (deploy_origin / deploy_cache). The moves keep an
# already-applied landing zone in place instead of destroying and recreating it.
moved {
  from = module.origin_network
  to   = module.origin_network[0]
}

moved {
  from = module.cache_network
  to   = module.cache_network[0]
}

moved {
  from = module.peering
  to   = module.peering[0]
}
