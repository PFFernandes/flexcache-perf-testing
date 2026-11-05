# Layer 3 - helper EC2: the network hop that lets stack 04-flexcache, running
# on your Mac, reach both FSx for ONTAP management IPs.
#   In the origin VPC when deploy_origin = true (reaches the cache over the
#   peering), otherwise in the cache VPC. Access only via EC2 Instance Connect
#   Endpoint; no internet, no NAT.
# Reads the VPC/subnets from the 01-landing-zone state.

data "terraform_remote_state" "lz" {
  backend = "local"
  config = {
    path = "${path.root}/../01-landing-zone/terraform.tfstate"
  }
}

locals {
  lz   = data.terraform_remote_state.lz.outputs
  side = var.deploy_origin ? "origin" : "cache"
  net  = try(local.lz[local.side], null)
}

resource "terraform_data" "landing_zone_check" {
  lifecycle {
    precondition {
      condition     = local.net != null
      error_message = "No Network ${local.side == "origin" ? "Origin" : "Cache"} in the 01-landing-zone state. Run ./tf.sh 01-landing-zone apply first."
    }
  }
}

module "helper_origin" {
  count = local.side == "origin" && local.net != null ? 1 : 0

  source    = "../../modules/06-helper-ec2"
  providers = { aws = aws.origin }

  name          = "${local.name_prefix}-helper"
  vpc_id        = local.net.vpc_id
  subnet_id     = local.net.private_subnet_ids[0] # first AZ, same as Single-AZ FSx for ONTAP
  instance_type = var.helper_instance_type
  architecture  = var.helper_architecture
}

module "helper_cache" {
  count = local.side == "cache" && local.net != null ? 1 : 0

  source    = "../../modules/06-helper-ec2"
  providers = { aws = aws.cache }

  name          = "${local.name_prefix}-helper"
  vpc_id        = local.net.vpc_id
  subnet_id     = local.net.private_subnet_ids[0]
  instance_type = var.helper_instance_type
  architecture  = var.helper_architecture
}

locals {
  helper = one(concat(module.helper_origin, module.helper_cache))
}
