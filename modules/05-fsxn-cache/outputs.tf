output "security_group_id" {
  description = "Security group attached to the FSx for ONTAP Cache (NFS, ONTAP management, intercluster)."
  value       = aws_security_group.fsxn.id
}

# TODO (layer 2) - planned outputs, added with the file system resources:
#
#   file_system_id
#   management_ip         endpoints[0].management[0].ip_addresses[0]
#   intercluster_ips      endpoints[0].intercluster[0].ip_addresses
#   svm_id / svm_name
#   svm_nfs_ip            SVM endpoints[0].nfs[0].ip_addresses[0]
#   fsxadmin_secret_arn
