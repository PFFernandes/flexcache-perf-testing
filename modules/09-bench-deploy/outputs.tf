output "bench_home" {
  value = "/opt/bench"
}

output "bundle_sha256" {
  description = "Hash of the deployed bench files; also in /opt/bench/VERSION.json on each client."
  value       = local.bundle_hash
}

output "file_count" {
  value = length(local.files)
}

output "deployed_to" {
  value = { for side, c in var.clients : side => c.instance_id }
}
