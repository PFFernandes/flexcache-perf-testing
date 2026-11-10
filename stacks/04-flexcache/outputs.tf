output "flexcache" {
  description = "null until the FlexCache is configured."
  value = length(module.flexcache) == 0 ? null : {
    name          = module.flexcache[0].flexcache_name
    junction_path = module.flexcache[0].flexcache_junction_path
    mount_source  = var.protocol == "nfs" ? "${local.cache.svm_nfs_ip}:${module.flexcache[0].flexcache_junction_path}" : null
    smb_shares = var.protocol == "smb" ? {
      origin = "\\\\${local.origin.svm_smb_ip}\\${var.share_names.origin}"
      cache  = "\\\\${local.cache.svm_smb_ip}\\${var.share_names.cache}"
    } : null
    configured_on = local.client.instance_id
  }
}
