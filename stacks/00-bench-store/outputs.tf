output "buckets" {
  description = "Package bucket each side reads from: the origin bucket, or the cache region's bucket when it differs."
  value = {
    origin = {
      bucket = module.store_origin.bucket
      arn    = module.store_origin.arn
      region = var.origin_region
    }
    cache = local.cross_region ? {
      bucket = module.store_cache[0].bucket
      arn    = module.store_cache[0].arn
      region = var.cache_region
      } : {
      bucket = module.store_origin.bucket
      arn    = module.store_origin.arn
      region = var.origin_region
    }
  }
}

output "home_bucket" {
  value = module.store_origin.bucket
}
