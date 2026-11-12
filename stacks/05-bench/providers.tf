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
  # Creator tag on every AWS resource (via each provider's default_tags); each
  # resource adds its own Name.
  tags = { Creator = var.creator }

  # Every Name starts with this, e.g. pedro-flexcache-perf-origin-vpc.
  name_prefix = "${var.creator}-${var.project}"
}

# aws.origin: the clients' IAM policies (IAM is global) and vol_bench when it's on the origin.
# aws.cache: vol_bench when results_volume.side = "cache".
# SSM Run Command goes through the AWS CLI with each client's own region.
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
