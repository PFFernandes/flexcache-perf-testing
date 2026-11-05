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

# origin_azs / cache_azs are only used by 01-landing-zone (they shape the subnets);
# declared here so the shared common.tfvars passes without warnings.

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

# --- toggles ---------------------------------------------------------------

variable "enable_cache_fsxn" {
  description = "false = FSx for ONTAP Origin only. Flip to true and re-apply to add the FSx for ONTAP Cache (the Origin is untouched)."
  type        = bool
  default     = false
}

# --- sizing (origin and cache sized independently, so you can test e.g. a smaller cache) ---

variable "origin_fsxn" {
  description = "Sizing of the FSx for ONTAP Origin."
  type = object({
    deployment_type                 = optional(string, "SINGLE_AZ_1")
    storage_capacity_gib            = optional(number, 1024)
    throughput_capacity_per_ha_pair = optional(number, 128)
    ha_pairs                        = optional(number, 1)
  })
  default = {}
}

variable "cache_fsxn" {
  description = "Sizing of the FSx for ONTAP Cache."
  type = object({
    deployment_type                 = optional(string, "SINGLE_AZ_1")
    storage_capacity_gib            = optional(number, 1024)
    throughput_capacity_per_ha_pair = optional(number, 128)
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
