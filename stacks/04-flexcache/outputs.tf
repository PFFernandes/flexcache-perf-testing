output "flexcache" {
  description = "null until the FlexCache is configured."
  value = length(module.flexcache) == 0 ? null : {
    name          = module.flexcache[0].flexcache_name
    junction_path = module.flexcache[0].flexcache_junction_path
    mount_source  = "${local.cache.svm_nfs_ip}:${module.flexcache[0].flexcache_junction_path}"
    configured_on = local.client.instance_id
  }
}
