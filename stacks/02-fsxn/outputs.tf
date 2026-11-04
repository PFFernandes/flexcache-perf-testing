# Contract consumed by 04-flexcache (and the test scripts) via terraform_remote_state.
# Enabled once modules/fsxn-origin and modules/fsxn-cache expose their outputs (layer 2 implementation).
#
# output "origin" {
#   value = {
#     region              = var.origin_region
#     file_system_id      = module.fsxn_origin.file_system_id
#     management_ip       = module.fsxn_origin.management_ip
#     intercluster_ips    = module.fsxn_origin.intercluster_ips
#     svm_name            = module.fsxn_origin.svm_name
#     svm_nfs_ip          = module.fsxn_origin.svm_nfs_ip
#     fsxadmin_secret_arn = module.fsxn_origin.fsxadmin_secret_arn
#     volume_name         = var.origin_volume.name
#     junction_path       = var.origin_volume.junction_path
#   }
# }
#
# output "cache" {
#   value = var.enable_cache_fsxn ? {
#     region              = var.cache_region
#     file_system_id      = module.fsxn_cache[0].file_system_id
#     management_ip       = module.fsxn_cache[0].management_ip
#     intercluster_ips    = module.fsxn_cache[0].intercluster_ips
#     svm_name            = module.fsxn_cache[0].svm_name
#     svm_nfs_ip          = module.fsxn_cache[0].svm_nfs_ip
#     fsxadmin_secret_arn = module.fsxn_cache[0].fsxadmin_secret_arn
#   } : null
# }
