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
