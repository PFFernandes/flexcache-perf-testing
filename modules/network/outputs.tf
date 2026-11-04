output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  description = "AZ of each private subnet, same order as private_subnet_ids."
  value       = aws_subnet.private[*].availability_zone
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_route_table_ids" {
  value = [aws_route_table.private.id]
}

output "public_route_table_ids" {
  value = aws_route_table.public[*].id
}

output "nat_public_ip" {
  value = try(aws_eip.nat[0].public_ip, null)
}
