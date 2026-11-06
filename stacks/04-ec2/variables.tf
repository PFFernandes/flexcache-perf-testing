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

# --- which clients -------------------------------------------------------------

variable "origin_ec2" {
  description = "Deploy the origin client (needs deploy_origin and the FSx for ONTAP Origin)."
  type        = bool
  default     = true
}

variable "cache_ec2" {
  description = "Deploy the cache client (needs deploy_cache and the FSx for ONTAP Cache)."
  type        = bool
  default     = true
}

# --- instance --------------------------------------------------------------------

variable "instance_type" {
  description = "Same type for both clients. t3.small is enough to check mounts; use a network-optimised type (e.g. c6in.xlarge) for real numbers."
  type        = string
  default     = "t3.small"
}

variable "architecture" {
  description = "x86_64 for t3/m7i/c6in, arm64 for Graviton (t4g, c7g ...)."
  type        = string
  default     = "x86_64"
}

# --- access ------------------------------------------------------------------------

variable "enable_eice" {
  description = "EC2 Instance Connect Endpoint per VPC (free): aws ec2-instance-connect ssh."
  type        = bool
  default     = true
}

variable "enable_ssm" {
  description = "SSM interface endpoints per VPC (3 x ~USD 0.01/h): aws ssm start-session."
  type        = bool
  default     = true
}

# --- NFS -------------------------------------------------------------------------------

variable "nfs_options" {
  description = "Mount options for every NFS mount. null = module default (vers=3,nconnect=8,hard,timeo=600,retrans=2,rsize/wsize=1 MiB)."
  type        = string
  default     = null
}

variable "flexcache_junction_path" {
  description = "Junction path of the FlexCache volume on the cache SVM (same as flexcache_junction_path in stacks/03-flexcache)."
  type        = string
  default     = "/vol_cache"
}

variable "cache_mounts_origin" {
  description = "Off by default: the cache client mounts only the FSx for ONTAP Cache. true = it also mounts the origin volume over the peering (/mnt/fsxn/vol_origin) as a no-cache baseline."
  type        = bool
  default     = false
}
