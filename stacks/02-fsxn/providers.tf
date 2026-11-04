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
  common_tags = {
    Project   = var.project
    Owner     = var.owner
    Stack     = "02-fsxn"
    ManagedBy = "terraform"
  }
}

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
