terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    netapp-ontap = {
      source  = "NetApp/netapp-ontap"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

locals {
  common_tags = {
    Project   = var.project
    Owner     = var.owner
    Stack     = "04-flexcache"
    ManagedBy = "terraform"
  }
}

# AWS is only used here to read the fsxadmin secrets.
provider "aws" {
  alias  = "origin"
  region = var.origin_region

  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "cache"
  region = var.cache_region

  default_tags {
    tags = local.common_tags
  }
}

# One ONTAP provider, two connection profiles. This is why the ONTAP layer is its
# own stack: provider settings must be known at plan time, so the FSxN endpoints
# have to exist (stack 02) before this stack is planned.
#
# Must run from a host that can reach both management IPs on TCP 443: the bastion,
# peered to both VPCs by 01-landing-zone (bastion_vpc_id).
provider "netapp-ontap" {
  connection_profiles = [
    {
      name           = "origin"
      hostname       = local.origin.management_ip
      username       = local.origin_creds.username
      password       = local.origin_creds.password
      validate_certs = false # FSxN management uses a self-signed certificate
    },
    {
      name           = "cache"
      hostname       = try(local.cache.management_ip, "")
      username       = try(local.cache_creds.username, "")
      password       = try(local.cache_creds.password, "")
      validate_certs = false
    },
  ]
}
