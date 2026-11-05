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
  # The only tag on every AWS resource (via each provider's default_tags).
  tags = { Creator = var.creator }
}

# AWS is only used here to read the shared fsxadmin secret (origin region).
provider "aws" {
  alias  = "origin"
  region = var.origin_region

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "cache"
  region = var.cache_region

  default_tags {
    tags = local.tags
  }
}

# One ONTAP provider, two connection profiles. This is why the ONTAP layer is its
# own stack: provider settings must be known at plan time, so the FSxN endpoints
# have to exist (stack 02) before this stack is planned.
#
# The management IPs are private, so from your Mac the provider goes through
# local SSM port forwards opened by scripts/ontap-tunnel.sh (via the origin
# EC2 client). Keep that script running while you plan/apply this stack.
provider "netapp-ontap" {
  connection_profiles = [
    {
      name           = "origin"
      hostname       = var.origin_ontap_endpoint
      username       = local.fsxadmin.username
      password       = local.fsxadmin.password
      validate_certs = false # FSxN management uses a self-signed certificate
    },
    {
      name           = "cache"
      hostname       = var.cache_ontap_endpoint
      username       = local.fsxadmin.username # same credentials as the Origin
      password       = local.fsxadmin.password
      validate_certs = false
    },
  ]
}
