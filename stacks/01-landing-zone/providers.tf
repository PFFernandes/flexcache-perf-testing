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
  # The only tag on every AWS resource (via each provider's default_tags).
  tags = { Creator = var.creator }
}

# Two aliases are always configured. If origin_region == cache_region they simply
# point at the same region, so the same code covers in-region and cross-region tests.

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

# Region of the (manually created) bastion VPC. Only used when bastion_vpc_id is set.
provider "aws" {
  alias  = "bastion"
  region = coalesce(var.bastion_region, var.origin_region)

  default_tags {
    tags = local.tags
  }
}
