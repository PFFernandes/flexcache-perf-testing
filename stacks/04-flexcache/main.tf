# Layer 4 - FlexCache: cluster peering + SVM peering + FlexCache volume, and with
# protocol = "smb" the SMB shares Origin (origin SVM) and Cache (cache SVM).
#
# Configured FROM THE ORIGIN EC2 CLIENT (stacks/03-ec2): Terraform sends a script
# to it with SSM Run Command, and the client calls the ONTAP REST API on both
# FSx for ONTAP management IPs (Origin locally, Cache over the peering).
# Nothing has to reach the management IPs from the operator machine.
#
# Needs: both FSx for ONTAP (02-fsxn) and the origin client with SSM (03-ec2).

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

data "terraform_remote_state" "ec2" {
  backend = "local"
  config = {
    path = "${path.root}/../03-ec2/terraform.tfstate"
  }
}

locals {
  net    = try(data.terraform_remote_state.lz.outputs.origin, null)
  origin = try(data.terraform_remote_state.fsxn.outputs.origin, null)
  cache  = try(data.terraform_remote_state.fsxn.outputs.cache, null)
  secret = try(data.terraform_remote_state.fsxn.outputs.fsxadmin_secret, null)
  client = try(data.terraform_remote_state.ec2.outputs.origin_client, null)

  ready = local.net != null && local.origin != null && local.cache != null && local.secret != null && local.client != null
}

resource "terraform_data" "prerequisites" {
  lifecycle {
    precondition {
      condition     = local.net != null
      error_message = "No Network Origin in the 01-landing-zone state. Set deploy_origin = true and apply 01-landing-zone first."
    }
    precondition {
      condition     = local.secret != null
      error_message = "No fsxadmin secret in the 02-fsxn state. Apply 02-fsxn first."
    }
    precondition {
      condition     = local.origin != null && local.cache != null
      error_message = "FlexCache needs both FSx for ONTAP. Set deploy_origin = true and deploy_cache = true in common.tfvars and apply 01-landing-zone and 02-fsxn first."
    }
    precondition {
      condition     = local.client != null
      error_message = "The FlexCache configuration runs on the origin EC2 client, which is not in the 03-ec2 state. Apply 03-ec2 (origin_ec2 = true) first."
    }
    precondition {
      condition     = var.protocol == "nfs" || try(local.client.os, "linux") == "windows"
      error_message = "protocol = \"smb\" but the origin client in the 03-ec2 state is not Windows. Re-apply 02-fsxn and 03-ec2 with protocol = \"smb\" first."
    }
    precondition {
      condition     = try(local.client.ssm_enabled, false)
      error_message = "The origin EC2 client needs SSM (enable_ssm = true in stacks/03-ec2): the configuration is sent to it with SSM Run Command."
    }
  }
}

module "flexcache" {
  count  = local.ready && try(local.client.ssm_enabled, false) ? 1 : 0
  source = "../../modules/08-ontap-flexcache"

  providers = { aws = aws.origin }

  name = "${local.name_prefix}-flexcache"

  client_instance_id = local.client.instance_id
  client_region      = local.client.region
  client_os          = try(local.client.os, "linux")
  client_role_name   = local.client.role_name
  vpc_id             = local.net.vpc_id
  vpc_cidr           = local.net.vpc_cidr
  subnet_id          = local.net.private_subnet_ids[0]

  # A Windows origin client already has a Secrets Manager endpoint (stacks/03-ec2).
  create_secrets_endpoint = var.create_secrets_endpoint && !try(local.client.secrets_endpoint, false)

  fsxadmin_secret_arn    = local.secret.arn
  fsxadmin_secret_region = local.secret.region

  origin = {
    management_ip    = local.origin.management_ip
    intercluster_ips = local.origin.intercluster_ips
    svm_name         = local.origin.svm_name
    volume_name      = local.origin.volume_name
    junction_path    = local.origin.junction_path
  }
  cache = {
    management_ip    = local.cache.management_ip
    intercluster_ips = local.cache.intercluster_ips
    svm_name         = local.cache.svm_name
  }

  flexcache_name          = var.flexcache_name
  flexcache_size_gib      = var.flexcache_size_gib
  flexcache_junction_path = var.flexcache_junction_path
  aggregates              = var.cache_aggregates

  protocol    = var.protocol
  share_names = var.share_names
}
