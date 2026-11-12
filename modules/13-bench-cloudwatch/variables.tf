variable "name" {
  description = "Prefix of the resources, e.g. pedro-flexcache-perf-origin-bench."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_id" {
  description = "Subnet of the EC2 client (the endpoint's network interface goes there)."
  type        = string
}

variable "client_role_name" {
  description = "IAM role of the EC2 client; gets PutMetricData in var.namespace."
  type        = string
}

variable "namespace" {
  description = "CloudWatch namespace the bench writes to."
  type        = string
  default     = "FlexCacheBench"
}
