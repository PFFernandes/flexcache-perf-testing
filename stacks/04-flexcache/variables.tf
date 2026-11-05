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

# origin_azs / cache_azs are only used by 01-landing-zone (they shape the subnets);
# declared here so the shared common.tfvars passes without warnings.

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

# --- ONTAP endpoints (local ends of scripts/ontap-tunnel.sh) -----------------

variable "origin_ontap_endpoint" {
  description = "host:port the ONTAP provider uses for the FSx for ONTAP Origin management API."
  type        = string
  default     = "localhost:8443"
}

variable "cache_ontap_endpoint" {
  description = "host:port the ONTAP provider uses for the FSx for ONTAP Cache management API."
  type        = string
  default     = "localhost:9443"
}

# --- FlexCache -------------------------------------------------------------

variable "flexcache_name" {
  type    = string
  default = "vol_cache"
}

variable "flexcache_size_gib" {
  type    = number
  default = 500
}

variable "flexcache_junction_path" {
  type    = string
  default = "/vol_cache"
}

variable "cache_aggregates" {
  type    = list(string)
  default = ["aggr1"]
}
