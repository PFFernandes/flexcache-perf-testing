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

# --- toggles ---------------------------------------------------------------

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
  description = "The origin volume the test dataset is written to and the FlexCache points at. FlexGroup with storage efficiency on by default."
  type = object({
    name                       = optional(string, "vol_origin")
    size_gib                   = optional(number, 800) # FlexGroup minimum: 100 GiB x 8 constituents
    junction_path              = optional(string, "/vol_origin")
    volume_style               = optional(string, "FLEXGROUP")
    constituents_per_aggregate = optional(number, null)
    storage_efficiency_enabled = optional(bool, true)
  })
  default = {}
}

variable "svm_netbios_names" {
  description = "protocol = \"smb\" only: SMB server names of the SVMs in the domain (up to 15 characters each)."
  type = object({
    origin = optional(string, "origin")
    cache  = optional(string, "cache")
  })
  default = {}

  validation {
    condition     = alltrue([for n in values(var.svm_netbios_names) : can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$", n))])
    error_message = "Each NetBIOS name must be 1-15 letters, digits or hyphens."
  }
}
