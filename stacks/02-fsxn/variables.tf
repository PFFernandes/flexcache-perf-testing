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

# --- toggles ---------------------------------------------------------------

variable "enable_cache_fsxn" {
  description = "false = origin FSxN only. Flip to true and re-apply to add the cache FSxN (origin is untouched)."
  type        = bool
  default     = false
}

# --- sizing (origin and cache sized independently, so you can test e.g. a smaller cache) ---

variable "origin_fsxn" {
  type = object({
    deployment_type                 = optional(string, "SINGLE_AZ_2")
    storage_capacity_gib            = optional(number, 1024)
    throughput_capacity_per_ha_pair = optional(number, 1536)
    ha_pairs                        = optional(number, 1)
  })
  default = {}
}

variable "cache_fsxn" {
  type = object({
    deployment_type                 = optional(string, "SINGLE_AZ_2")
    storage_capacity_gib            = optional(number, 1024)
    throughput_capacity_per_ha_pair = optional(number, 1536)
    ha_pairs                        = optional(number, 1)
  })
  default = {}
}

variable "origin_volume" {
  description = "The origin FlexVol that the test dataset is written to and the FlexCache points at."
  type = object({
    name          = optional(string, "vol_origin")
    size_gib      = optional(number, 800)
    junction_path = optional(string, "/vol_origin")
  })
  default = {}
}
