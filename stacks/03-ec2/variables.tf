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

variable "enable_cache_ec2" {
  description = "false = origin client only. Flip to true and re-apply to add a client in the cache VPC."
  type        = bool
  default     = false
}

# --- sizing ----------------------------------------------------------------

variable "origin_instance_type" {
  type    = string
  default = "c6in.2xlarge"
}

variable "cache_instance_type" {
  type    = string
  default = "c6in.2xlarge"
}

variable "key_name" {
  description = "Optional EC2 key pair name (must exist in each region). Default access is SSM."
  type        = string
  default     = null
}
