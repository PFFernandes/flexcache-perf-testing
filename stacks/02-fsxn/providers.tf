terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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
