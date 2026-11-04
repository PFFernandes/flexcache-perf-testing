terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  common_tags = {
    Project   = var.project
    Owner     = var.owner
    Stack     = "01-landing-zone"
    ManagedBy = "terraform"
  }
}

# Two aliases are always configured. If origin_region == cache_region they simply
# point at the same region, so the same code covers in-region and cross-region tests.

provider "aws" {
  alias  = "origin"
  region = var.origin_region

  default_tags {
    tags = merge(local.common_tags, { Side = "origin" })
  }
}

provider "aws" {
  alias  = "cache"
  region = var.cache_region

  default_tags {
    tags = merge(local.common_tags, { Side = "cache" })
  }
}

# Region of the (manually created) bastion VPC. Only used when bastion_vpc_id is set.
provider "aws" {
  alias  = "bastion"
  region = coalesce(var.bastion_region, var.origin_region)

  default_tags {
    tags = merge(local.common_tags, { Side = "bastion" })
  }
}
