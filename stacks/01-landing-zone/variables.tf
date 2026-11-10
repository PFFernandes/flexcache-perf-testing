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

variable "deploy_origin" {
  description = "Deploy the Origin side: Network Origin (01-landing-zone) and FSx for ONTAP Origin (02-fsxn)."
  type        = bool
  default     = true
}

variable "deploy_cache" {
  description = "Deploy the Cache side: Network Cache (01-landing-zone) and FSx for ONTAP Cache (02-fsxn)."
  type        = bool
  default     = true

  validation {
    condition     = var.deploy_origin || var.deploy_cache
    error_message = "Nothing to deploy: set deploy_origin and/or deploy_cache to true in common.tfvars."
  }
}

variable "protocol" {
  description = "File protocol of the lab: nfs (default, Linux clients) or smb (AWS Managed AD, Windows clients, shares Origin and Cache)."
  type        = string
  default     = "nfs"

  validation {
    condition     = contains(["nfs", "smb"], var.protocol)
    error_message = "protocol must be \"nfs\" or \"smb\"."
  }

  validation {
    condition     = var.protocol == "nfs" || var.deploy_origin
    error_message = "protocol = \"smb\" needs deploy_origin = true: the Managed AD lives in the origin VPC."
  }
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
  description = "true = public subnet + internet gateway + NAT gateway in the origin VPC. FSx for ONTAP never needs it; keep it off unless you add instances that need the internet."
  type        = bool
  default     = false
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
  description = "true = public subnet + internet gateway + NAT gateway in the cache VPC. FSx for ONTAP never needs it; keep it off unless you add instances that need the internet."
  type        = bool
  default     = false
}

# --- Managed AD (protocol = "smb" only) ------------------------------------

variable "ad_domain_name" {
  description = "Domain of the AWS Managed Microsoft AD created when protocol = \"smb\"."
  type        = string
  default     = "flexcache.lab"
}

variable "ad_short_name" {
  description = "NetBIOS name of the domain (up to 15 characters)."
  type        = string
  default     = "FLEXCACHE"
}

variable "ad_edition" {
  description = "Standard (enough for this lab) or Enterprise."
  type        = string
  default     = "Standard"
}

variable "ad_az" {
  description = "AZ letter of the second subnet the directory needs, when origin_azs has only one. null = the first of a, b, c ... not in origin_azs."
  type        = string
  default     = null
}

variable "ad_subnet_cidr" {
  description = "CIDR of that second subnet. null = x.x.200.0/24 from origin_vpc_cidr."
  type        = string
  default     = null
}
