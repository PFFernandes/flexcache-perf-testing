output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "eice_id" {
  value = try(aws_ec2_instance_connect_endpoint.this[0].id, null)
}

output "os" {
  value = var.os
}

output "mounts" {
  description = "Linux: mount point => NFS source. Windows: drive => SMB share."
  value = (local.windows
    ? { for share, m in var.smb_mappings : "${m.drive}:" => "\\\\${m.server}\\${share}" }
  : { for k, m in var.nfs_mounts : "/mnt/fsxn/${k}" => "${m.server}:${m.export}" })
}

output "domain" {
  description = "Windows: AD domain the client joins (domain_join); null otherwise."
  value       = try(var.domain_join.domain_name, null)
}

output "connect_eice" {
  description = "Linux: SSH command. Windows: RDP tunnel; then connect your RDP client to localhost:13389 as <short_name>\\Admin (domain joined) or Administrator."
  value = length(aws_ec2_instance_connect_endpoint.this) == 0 ? null : (local.windows
    ? "aws ec2-instance-connect open-tunnel --instance-id ${aws_instance.this.id} --remote-port 3389 --local-port 13389 --region ${data.aws_region.current.region}"
  : "aws ec2-instance-connect ssh --instance-id ${aws_instance.this.id} --connection-type eice --region ${data.aws_region.current.region}")
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

output "secrets_endpoint" {
  description = "true when this module created a Secrets Manager endpoint in the VPC (stacks/04-flexcache then doesn't)."
  value       = var.enable_secrets_endpoint
}
