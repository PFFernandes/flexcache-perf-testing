# Layer 3 - Linux test clients.
#   Origin client: when deploy_origin = true (writes the test dataset to the origin volume).
#   Cache client:  when deploy_cache = true and enable_cache_ec2 = true (read benchmark).
#
# Depends only on 01-landing-zone, so it can be deployed before, after or in
# parallel with 02-fsxn (FSxN creation can take 30+ minutes; the clients do not need to wait).

data "terraform_remote_state" "lz" {
  backend = "local"
  config = {
    path = "${path.root}/../01-landing-zone/terraform.tfstate"
  }
}

locals {
  lz = data.terraform_remote_state.lz.outputs

  # SSH/ICMP from both test VPCs. You reach the clients from your Mac with SSM
  # Session Manager, so nothing is open to the internet.
  allowed_cidrs = compact([
    try(local.lz.origin.vpc_cidr, null),
    try(local.lz.cache.vpc_cidr, null),
  ])
}

module "ec2_origin" {
  count = var.deploy_origin ? 1 : 0

  source    = "../../modules/06-ec2-client"
  providers = { aws = aws.origin }

  name                  = "${local.name_prefix}-origin-client"
  vpc_id                = local.lz.origin.vpc_id
  subnet_id             = local.lz.origin.private_subnet_ids[0] # same AZ as Single-AZ FSxN
  instance_type         = var.origin_instance_type
  key_name              = var.key_name
  allowed_ingress_cidrs = local.allowed_cidrs
}

module "ec2_cache" {
  count = var.deploy_cache && var.enable_cache_ec2 ? 1 : 0

  source    = "../../modules/06-ec2-client"
  providers = { aws = aws.cache }

  name                  = "${local.name_prefix}-cache-client"
  vpc_id                = local.lz.cache.vpc_id
  subnet_id             = local.lz.cache.private_subnet_ids[0]
  instance_type         = var.cache_instance_type
  key_name              = var.key_name
  allowed_ingress_cidrs = local.allowed_cidrs
}

# ec2_origin got a count (deploy_origin); keep an already-applied client in place.
moved {
  from = module.ec2_origin
  to   = module.ec2_origin[0]
}
