variable "name" {
  description = "Name of the helper and prefix of its resources, e.g. pedro-flexcache-perf-helper."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the helper and its EC2 Instance Connect Endpoint."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet for the helper and the EICE (default: the first AZ)."
  type        = string
}

variable "instance_type" {
  description = "Only forwards TCP, so the smallest size is enough."
  type        = string
  default     = "t4g.small"
}

variable "architecture" {
  description = "arm64 for Graviton types (t4g, c7g, ...), x86_64 otherwise. Used to pick the AL2023 AMI."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "ami_id" {
  description = "null = latest Amazon Linux 2023 (has EC2 Instance Connect preinstalled)."
  type        = string
  default     = null
}

variable "root_volume_gib" {
  type    = number
  default = 8
}
