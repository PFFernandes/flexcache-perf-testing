# Contract consumed by 03-flexcache (and the test scripts) via terraform_remote_state.

# One secret for both FSx for ONTAP (same fsxadmin password), in the origin region.
output "fsxadmin_secret" {
  description = "Secrets Manager secret with the fsxadmin credentials shared by the Origin and the Cache."
  value = {
    arn    = aws_secretsmanager_secret.fsxadmin.arn
    region = var.origin_region
  }
}

# One output per side; null when that side is not deployed (deploy_origin / deploy_cache).

output "origin" {
  description = "FSx for ONTAP Origin: endpoints, SVM and volume. null when deploy_origin = false."
  value = length(module.fsxn_origin) > 0 ? {
    region           = var.origin_region
    file_system_id   = module.fsxn_origin[0].file_system_id
    management_ip    = module.fsxn_origin[0].management_ip
    intercluster_ips = module.fsxn_origin[0].intercluster_ips
    svm_name         = module.fsxn_origin[0].svm_name
    svm_nfs_ip       = module.fsxn_origin[0].svm_nfs_ip
    volume_name      = var.origin_volume.name
    volume_style     = var.origin_volume.volume_style
    junction_path    = var.origin_volume.junction_path
  } : null
}

output "cache" {
  description = "FSx for ONTAP Cache: endpoints and SVM. null when deploy_cache = false."
  value = length(module.fsxn_cache) > 0 ? {
    region           = var.cache_region
    file_system_id   = module.fsxn_cache[0].file_system_id
    management_ip    = module.fsxn_cache[0].management_ip
    intercluster_ips = module.fsxn_cache[0].intercluster_ips
    svm_name         = module.fsxn_cache[0].svm_name
    svm_nfs_ip       = module.fsxn_cache[0].svm_nfs_ip
  } : null
}
