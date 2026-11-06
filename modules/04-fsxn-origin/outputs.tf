output "security_group_id" {
  description = "Security group attached to the FSx for ONTAP Origin (NFS, ONTAP management, intercluster)."
  value       = aws_security_group.fsxn.id
}

output "file_system_id" {
  value = aws_fsx_ontap_file_system.this.id
}

output "management_ip" {
  description = "ONTAP management endpoint (REST API / SSH) - what stacks/04-flexcache connects to."
  value       = sort(tolist(aws_fsx_ontap_file_system.this.endpoints[0].management[0].ip_addresses))[0]
}

output "intercluster_ips" {
  description = "Intercluster LIFs used for cluster peering and FlexCache traffic."
  value       = sort(tolist(aws_fsx_ontap_file_system.this.endpoints[0].intercluster[0].ip_addresses))
}

output "svm_id" {
  value = aws_fsx_ontap_storage_virtual_machine.this.id
}

output "svm_name" {
  value = aws_fsx_ontap_storage_virtual_machine.this.name
}

output "svm_nfs_ip" {
  description = "NFS endpoint of the SVM - what the clients mount."
  value       = sort(tolist(aws_fsx_ontap_storage_virtual_machine.this.endpoints[0].nfs[0].ip_addresses))[0]
}

output "volumes" {
  description = "Origin volumes: name => { id, junction_path }."
  value       = { for k, v in aws_fsx_ontap_volume.this : k => { id = v.id, junction_path = v.junction_path } }
}
