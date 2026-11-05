# Layer 3 - Linux test clients.
#   Origin client: always (writes the test dataset to the origin volume).
#   Cache client:  only when enable_cache_ec2 = true (read benchmark against the FlexCache).
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

  # SSH/ICMP from both test VPCs and from the bastion VPC (when peered).
  allowed_cidrs = compact([
    local.lz.origin.vpc_cidr,
    local.lz.cache.vpc_cidr,
    try(local.lz.bastion.vpc_cidr, null),
  ])
}

module "ec2_origin" {
  source    = "../../modules/06-ec2-client"
  providers = { aws = aws.origin }

  name                  = "${var.project}-origin-client"
  vpc_id                = local.lz.origin.vpc_id
  subnet_id             = local.lz.origin.private_subnet_ids[0] # same AZ as Single-AZ FSxN
  instance_type         = var.origin_instance_type
  key_name              = var.key_name
  allowed_ingress_cidrs = local.allowed_cidrs
}

module "ec2_cache" {
  count = var.enable_cache_ec2 ? 1 : 0

  source    = "../../modules/06-ec2-client"
  providers = { aws = aws.cache }

  name                  = "${var.project}-cache-client"
  vpc_id                = local.lz.cache.vpc_id
  subnet_id             = local.lz.cache.private_subnet_ids[0]
  instance_type         = var.cache_instance_type
  key_name              = var.key_name
  allowed_ingress_cidrs = local.allowed_cidrs
}
