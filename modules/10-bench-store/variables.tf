variable "bucket_name" {
  description = "Globally unique bucket name, e.g. pedro-flexcache-perf-bench-123456789012-eu-west-1."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 lowercase letters, digits, dots or hyphens."
  }
}

variable "noncurrent_version_days" {
  description = "Days an overwritten or deleted object version is kept before it expires."
  type        = number
  default     = 30
}
