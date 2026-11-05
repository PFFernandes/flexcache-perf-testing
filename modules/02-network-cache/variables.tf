variable "name" {
  description = "Name prefix for every resource in the Cache VPC, e.g. pedro-flexcache-perf-cache (Name tag = <prefix>-vpc, <prefix>-private-<az>, ...)."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Must not overlap with the peer VPC."
  type        = string
}

variable "private_subnet_cidrs" {
  description = "Private subnets (FSx for ONTAP). One per AZ, in AZ order. Single-AZ FSxN uses the first, Multi-AZ the first two."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) >= 1 && (length(var.azs) == 0 || length(var.private_subnet_cidrs) == length(var.azs))
    error_message = "Give exactly one private subnet per AZ in azs (at least one)."
  }
}

variable "public_subnet_cidrs" {
  description = "Public subnets (only used for the NAT gateway). Empty list = no internet gateway, no NAT."
  type        = list(string)
  default     = []
}

variable "azs" {
  description = "Availability zones, in order (e.g. [\"eu-west-1a\"]). Private subnet i goes to azs[i]; public subnets start in azs[0]. Empty = first available AZs in the region."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Create a single NAT gateway so private instances can reach the internet (package installs, SSM). Requires a public subnet."
  type        = bool
  default     = false
}

variable "enable_s3_gateway_endpoint" {
  description = "Free S3 gateway endpoint: Amazon Linux 2023 package repos are reachable through it even without NAT."
  type        = bool
  default     = true
}
