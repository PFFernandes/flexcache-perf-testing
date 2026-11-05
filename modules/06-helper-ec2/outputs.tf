output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "eice_id" {
  value = aws_ec2_instance_connect_endpoint.this.id
}

output "os_user" {
  description = "Login user on Amazon Linux 2023."
  value       = "ec2-user"
}
