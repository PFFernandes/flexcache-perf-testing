output "volume_id" {
  value = aws_fsx_ontap_volume.this.id
}

output "volume_name" {
  value = aws_fsx_ontap_volume.this.name
}

output "junction_path" {
  value = aws_fsx_ontap_volume.this.junction_path
}

output "svm_name" {
  value = data.aws_fsx_ontap_storage_virtual_machine.svm.name
}
