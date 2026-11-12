output "telemetry_files" {
  description = "Where each client's telemetry ends up on the results volume, after bench-results-sync."
  value       = local.results_paths
}

output "staging_dir" {
  description = "Local folder on each client where results are written during a test."
  value       = var.staging_dir
}

output "results_mount" {
  value = var.results.mount_point
}

output "collector_version" {
  value = var.collector_version
}
