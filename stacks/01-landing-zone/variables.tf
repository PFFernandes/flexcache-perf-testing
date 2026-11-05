# --- common (from ../../common.tfvars) --------------------------------------

variable "project" {
  type = string
}

variable "creator" {
  description = "Creator tag on every AWS resource, and the start of every Name (<creator>-<project>-...)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.creator))
    error_message = "creator is used in resource names: lowercase letters, digits and hyphens only, e.g. \"pedro\"."
  }
}

variable "origin_region" {
  type = string
}

variable "cache_region" {
  type = string
}

variable "origin_azs" {
  description = "AZ letters for the origin side, appended to origin_region (\"a\" = <region>a). One private subnet per AZ. Single-AZ FSxN uses the first, Multi-AZ needs two, e.g. [\"a\", \"b\"]."
  type        = list(string)
  default     = ["a"]

  validation {
    condition     = length(var.origin_azs) >= 1 && alltrue([for s in var.origin_azs : can(regex("^[a-z]$", s))])
    error_message = "origin_azs must be a non-empty list of AZ letters, e.g. [\"a\"] or [\"a\", \"b\"]."
  }
}

variable "cache_azs" {
  description = "AZ letters for the cache side, appended to cache_region. Same rules as origin_azs."
  type        = list(string)
  default     = ["a"]

  validation {
    condition     = length(var.cache_azs) >= 1 && alltrue([for s in var.cache_azs : can(regex("^[a-z]$", s))])
    error_message = "cache_azs must be a non-empty list of AZ letters, e.g. [\"a\"] or [\"a\", \"b\"]."
  }
}

# --- origin VPC ------------------------------------------------------------

variable "origin_vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "origin_private_subnet_cidrs" {
  description = "One per AZ in origin_azs, same order. null = 10.10.1.0/24, 10.10.2.0/24, ... (one /24 per AZ, from origin_vpc_cidr)."
  type        = list(string)
  default     = null
}

variable "origin_public_subnet_cidrs" {
  description = "Only used for the NAT gateway, in the first AZ. null = one /24 (x.x.101.0/24) when origin_nat_gateway = true, none otherwise. [] = no internet access from the VPC."
  type        = list(string)
  default     = null
}

variable "origin_nat_gateway" {
  type    = bool
  default = true
}

# --- cache VPC -------------------------------------------------------------

variable "cache_vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "cache_private_subnet_cidrs" {
  description = "One per AZ in cache_azs, same order. null = one /24 per AZ from cache_vpc_cidr."
  type        = list(string)
  default     = null
}

variable "cache_public_subnet_cidrs" {
  description = "Only used for the NAT gateway, in the first AZ. null = one /24 when cache_nat_gateway = true, none otherwise."
  type        = list(string)
  default     = null
}

variable "cache_nat_gateway" {
  type    = bool
  default = true
}
