# Layer 0 - Test bench package bucket(s): how software reaches the clients, which have no
# internet. Stack 05 copies the OpenTelemetry Collector package here (vendor/), and the
# clients download it through their region's S3 gateway endpoint.
#
# NO RESULTS are stored here: telemetry and dataset records go to the results volume
# (vol_bench, FSx for ONTAP, stacks/05-bench).
#
# Applied once per AWS account and project and left in place between labs, so the package
# isn't downloaded and uploaded again for every lab.
#
#   origin bucket  <creator>-<project>-bench-<account>-<origin_region>    always
#   cache bucket   <creator>-<project>-bench-<account>-<cache_region>     only when cache_region differs
#
# Read by stacks/05-bench (bucket names, regions).

data "aws_caller_identity" "current" {
  provider = aws.origin
}

locals {
  cross_region = var.cache_region != var.origin_region
  bucket_base  = "${local.name_prefix}-bench-${data.aws_caller_identity.current.account_id}"
}

module "store_origin" {
  source    = "../../modules/10-bench-store"
  providers = { aws = aws.origin }

  bucket_name             = "${local.bucket_base}-${var.origin_region}"
  noncurrent_version_days = var.noncurrent_version_days
}

module "store_cache" {
  count     = local.cross_region ? 1 : 0
  source    = "../../modules/10-bench-store"
  providers = { aws = aws.cache }

  bucket_name             = "${local.bucket_base}-${var.cache_region}"
  noncurrent_version_days = var.noncurrent_version_days
}
