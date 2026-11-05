# --- common (from ../../common.tfvars) --------------------------------------

variable "project" {
  type = string
}

variable "creator" {
  description = "Value of the Creator tag, the only tag put on every AWS resource."
  type        = string
}

variable "origin_region" {
  type = string
}

variable "cache_region" {
  type = string
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
