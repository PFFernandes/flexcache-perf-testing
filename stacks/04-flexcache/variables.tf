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
