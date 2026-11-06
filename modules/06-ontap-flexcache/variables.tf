# The calling stack configures ONE netapp-ontap provider with two connection
# profiles (origin + cache); this module references them by name.

variable "origin_cx_profile" {
  description = "netapp-ontap connection profile name for the origin cluster."
  type        = string
  default     = "origin"
}

variable "cache_cx_profile" {
  description = "netapp-ontap connection profile name for the cache cluster."
  type        = string
  default     = "cache"
}

variable "origin_intercluster_ips" {
  type = list(string)
}

variable "cache_intercluster_ips" {
  type = list(string)
}

variable "origin_svm_name" {
  type = string
}

variable "cache_svm_name" {
  type = string
}

variable "origin_volume_name" {
  description = "Existing origin FlexVol (created by stacks/02-fsxn)."
  type        = string
}

variable "flexcache_name" {
  type    = string
  default = "vol_cache"
}

variable "flexcache_size_gib" {
  description = "Size of the FlexCache volume. Smaller than the dataset = test cache eviction; larger = test warm-cache reads."
  type        = number
  default     = 500
}

variable "flexcache_junction_path" {
  type    = string
  default = "/vol_cache"
}

variable "aggregates" {
  description = "Cache-side aggregates. FSxN: aggr1 (add aggr2... for multi HA-pair SINGLE_AZ_2)."
  type        = list(string)
  default     = ["aggr1"]
}

variable "global_file_locking_enabled" {
  type    = bool
  default = false
}
