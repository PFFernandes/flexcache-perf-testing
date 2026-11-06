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

  # Every Name starts with this, e.g. pedro-flexcache-perf-origin-vpc.
  name_prefix = "${var.creator}-${var.project}"
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
# The provider connects to each FSx for ONTAP management IP (stack 02 output)
# on HTTPS 443. Those IPs are private: your Mac needs a network path into the
# VPCs (e.g. AWS Client VPN or Site-to-Site VPN). origin_ontap_endpoint /
# cache_ontap_endpoint override the target, e.g. for a local port forward.
provider "netapp-ontap" {
  connection_profiles = [
    {
      name           = "origin"
      hostname       = coalesce(var.origin_ontap_endpoint, try(local.origin.management_ip, ""))
      username       = local.fsxadmin.username
      password       = local.fsxadmin.password
      validate_certs = false # FSxN management uses a self-signed certificate
    },
    {
      name           = "cache"
      hostname       = coalesce(var.cache_ontap_endpoint, try(local.cache.management_ip, ""))
      username       = local.fsxadmin.username # same credentials as the Origin
      password       = local.fsxadmin.password
      validate_certs = false
    },
  ]
}
