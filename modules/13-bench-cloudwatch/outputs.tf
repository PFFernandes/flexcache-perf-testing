output "endpoint_id" {
  value = aws_vpc_endpoint.monitoring.id
}

output "region" {
  value = data.aws_region.current.region
}

output "namespace" {
  value = var.namespace
}
