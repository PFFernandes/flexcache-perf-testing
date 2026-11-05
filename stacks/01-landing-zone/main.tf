# Layer 1 - landing zone: Network Origin (origin VPC) + Network Cache (cache VPC)
# + VPC peering between them,
# plus (optional) peering from your bastion's VPC to both.
# Both VPCs are always created (they cost nothing except the optional NAT gateways),
# so the cache side is ready whenever you decide to deploy a cache FSxN / EC2.

# --- Network Origin ----------------------------------------------------------
module "origin_network" {
  source    = "../../modules/01-network-origin"
  providers = { aws = aws.origin }

  name                 = "${var.project}-origin"
  cidr_block           = var.origin_vpc_cidr
  private_subnet_cidrs = var.origin_private_subnet_cidrs
  public_subnet_cidrs  = var.origin_public_subnet_cidrs
  enable_nat_gateway   = var.origin_nat_gateway
}

# --- Network Cache -----------------------------------------------------------
module "cache_network" {
  source    = "../../modules/02-network-cache"
  providers = { aws = aws.cache }

  name                 = "${var.project}-cache"
  cidr_block           = var.cache_vpc_cidr
  private_subnet_cidrs = var.cache_private_subnet_cidrs
  public_subnet_cidrs  = var.cache_public_subnet_cidrs
  enable_nat_gateway   = var.cache_nat_gateway
}

module "peering" {
  source = "../../modules/03-vpc-peering"
  providers = {
    aws.requester = aws.origin
    aws.accepter  = aws.cache
  }

  name = "${var.project}-origin-to-cache"

  requester_vpc_id          = module.origin_network.vpc_id
  requester_cidr            = module.origin_network.vpc_cidr
  requester_route_table_ids = concat(module.origin_network.private_route_table_ids, module.origin_network.public_route_table_ids)

  accepter_vpc_id          = module.cache_network.vpc_id
  accepter_cidr            = module.cache_network.vpc_cidr
  accepter_route_table_ids = concat(module.cache_network.private_route_table_ids, module.cache_network.public_route_table_ids)
}

# --- Bastion peering (optional) ---------------------------------------------
# The bastion lives in a VPC you created by hand (e.g. the default VPC). Peering
# that VPC to both test VPCs lets the bastion reach the FSxN management IPs
# (needed by stack 04) and SSH to the EC2 clients. VPC peering is not transitive,
# so the bastion needs its own peering to each side.

locals {
  with_bastion = var.bastion_vpc_id != null
  bastion_cidr = try(data.aws_vpc.bastion[0].cidr_block, null)

  bastion_route_table_ids = (
    var.bastion_route_table_ids != null
    ? var.bastion_route_table_ids
    : try(data.aws_route_tables.bastion[0].ids, [])
  )
}

data "aws_vpc" "bastion" {
  count    = local.with_bastion ? 1 : 0
  provider = aws.bastion
  id       = var.bastion_vpc_id
}

data "aws_route_tables" "bastion" {
  count    = local.with_bastion && var.bastion_route_table_ids == null ? 1 : 0
  provider = aws.bastion
  vpc_id   = var.bastion_vpc_id
}

module "bastion_to_origin" {
  count  = local.with_bastion ? 1 : 0
  source = "../../modules/03-vpc-peering"
  providers = {
    aws.requester = aws.bastion
    aws.accepter  = aws.origin
  }

  name = "${var.project}-bastion-to-origin"

  requester_vpc_id          = var.bastion_vpc_id
  requester_cidr            = local.bastion_cidr
  requester_route_table_ids = local.bastion_route_table_ids

  accepter_vpc_id          = module.origin_network.vpc_id
  accepter_cidr            = module.origin_network.vpc_cidr
  accepter_route_table_ids = concat(module.origin_network.private_route_table_ids, module.origin_network.public_route_table_ids)
}

module "bastion_to_cache" {
  count  = local.with_bastion ? 1 : 0
  source = "../../modules/03-vpc-peering"
  providers = {
    aws.requester = aws.bastion
    aws.accepter  = aws.cache
  }

  name = "${var.project}-bastion-to-cache"

  requester_vpc_id          = var.bastion_vpc_id
  requester_cidr            = local.bastion_cidr
  requester_route_table_ids = local.bastion_route_table_ids

  accepter_vpc_id          = module.cache_network.vpc_id
  accepter_cidr            = module.cache_network.vpc_cidr
  accepter_route_table_ids = concat(module.cache_network.private_route_table_ids, module.cache_network.public_route_table_ids)
}
