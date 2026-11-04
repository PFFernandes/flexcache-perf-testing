# Enabled once modules/ontap-flexcache exposes its outputs (layer 4 implementation).
#
# output "flexcache" {
#   value = {
#     name          = module.flexcache.flexcache_name
#     junction_path = module.flexcache.flexcache_junction_path
#     mount_source  = "${local.cache.svm_nfs_ip}:${module.flexcache.flexcache_junction_path}"
#   }
# }
