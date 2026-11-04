variable "name" {
  description = "Name prefix for all resources in this VPC, e.g. flexcache-perf-origin."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Must not overlap with the peer VPC."
  type        = string
}

variable "private_subnet_cidrs" {
  description = "Private subnets (FSxN + EC2). One per AZ, in AZ order. Single-AZ FSxN uses the first, Multi-AZ the first two."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) >= 1
    error_message = "At least one private subnet is required."
  }
}

variable "public_subnet_cidrs" {
  description = "Public subnets (only used for the NAT gateway). Empty list = no internet gateway, no NAT."
  type        = list(string)
  default     = []
}

variable "azs" {
  description = "Availability zones to use, in order. Empty = first available AZs in the region."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Create a single NAT gateway so private instances can reach the internet (package installs, SSM). Requires a public subnet."
  type        = bool
  default     = true
}

variable "enable_s3_gateway_endpoint" {
  description = "Free S3 gateway endpoint: Amazon Linux 2023 package repos are reachable through it even without NAT."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags for every resource (provider default_tags already add Project/Owner/Stack)."
  type        = map(string)
  default     = {}
}
