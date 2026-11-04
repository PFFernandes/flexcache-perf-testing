output "peering_connection_id" {
  value = aws_vpc_peering_connection_accepter.this.id
}

output "cross_region" {
  value = local.cross_region
}
