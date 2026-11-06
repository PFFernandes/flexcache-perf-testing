output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "eice_id" {
  value = try(aws_ec2_instance_connect_endpoint.this[0].id, null)
}

output "mounts" {
  description = "Mount point => NFS source."
  value       = { for k, m in var.nfs_mounts : "/mnt/fsxn/${k}" => "${m.server}:${m.export}" }
}

output "connect_eice" {
  value = length(aws_ec2_instance_connect_endpoint.this) > 0 ? "aws ec2-instance-connect ssh --instance-id ${aws_instance.this.id} --connection-type eice --region ${data.aws_region.current.region}" : null
}

output "connect_ssm" {
  value = var.enable_ssm ? "aws ssm start-session --target ${aws_instance.this.id} --region ${data.aws_region.current.region}" : null
}

output "role_name" {
  description = "IAM role of the instance (stacks/04-flexcache adds read access to the fsxadmin secret)."
  value       = aws_iam_role.this.name
}

output "ssm_enabled" {
  value = var.enable_ssm
}
