# Contract consumed by 04-flexcache (and the test scripts) via terraform_remote_state.

# One secret for both FSx for ONTAP (same fsxadmin password), in the origin region.
output "fsxadmin_secret" {
  description = "Secrets Manager secret with the fsxadmin credentials shared by the Origin and the Cache."
  value = {
    arn    = aws_secretsmanager_secret.fsxadmin.arn
    region = var.origin_region
  }
}

# The per-side outputs below are enabled once modules/04-fsxn-origin and modules/05-fsxn-cache expose their outputs (layer 2 implementation).
#
# output "origin" {
#   value = {
#     region              = var.origin_region
#     file_system_id      = module.fsxn_origin.file_system_id
#     management_ip       = module.fsxn_origin.management_ip
#     intercluster_ips    = module.fsxn_origin.intercluster_ips
#     svm_name            = module.fsxn_origin.svm_name
#     svm_nfs_ip          = module.fsxn_origin.svm_nfs_ip
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
#   } : null
# }
