output "flexcache_name" {
  value = var.flexcache_name
}

output "flexcache_junction_path" {
  value = var.flexcache_junction_path
}

output "secrets_endpoint_id" {
  value = try(aws_vpc_endpoint.secretsmanager[0].id, null)
}
