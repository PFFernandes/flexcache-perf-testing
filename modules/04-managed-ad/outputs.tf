output "directory_id" {
  value = aws_directory_service_directory.this.id
}

output "domain_name" {
  value = aws_directory_service_directory.this.name
}

output "short_name" {
  value = aws_directory_service_directory.this.short_name
}

output "dns_ips" {
  description = "IP addresses of the two domain controllers, which are also the domain's DNS servers."
  value       = sort(tolist(aws_directory_service_directory.this.dns_ip_addresses))
}

output "security_group_id" {
  value = aws_directory_service_directory.this.security_group_id
}

output "computers_ou" {
  description = "OU the FSx for ONTAP SVMs join into. In AWS Managed AD only the delegated OU under <short_name> is writable."
  value       = "OU=Computers,OU=${var.short_name},${join(",", [for part in split(".", var.domain_name) : "DC=${part}"])}"
}

output "fsx_admins_group" {
  description = "Delegated group that AWS Managed AD creates for FSx administrators."
  value       = "AWS Delegated FSx Administrators"
}
