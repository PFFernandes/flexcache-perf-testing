# --- common (from ../../common.tfvars) --------------------------------------

variable "project" {
  type = string
}

variable "owner" {
  type = string
}

variable "origin_region" {
  type = string
}

variable "cache_region" {
  type = string
}

variable "extra_tags" {
  description = "Additional tags added to every AWS resource in every stack (e.g. CostCenter). Cannot override the standard tags."
  type        = map(string)
  default     = {}
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
