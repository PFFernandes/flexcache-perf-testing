variable "name" {
  description = "Prefix for the AWS resources of this module, e.g. pedro-flexcache-perf-flexcache."
  type        = string
}

# --- where the configuration runs: the origin EC2 client --------------------------

variable "client_instance_id" {
  description = "Origin EC2 client (stacks/03-ec2). Its SSM agent must be online (enable_ssm = true)."
  type        = string
}

variable "client_region" {
  type = string
}

variable "client_os" {
  description = "linux (runs flexcache.py) or windows (runs flexcache.ps1)."
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.client_os)
    error_message = "client_os must be linux or windows."
  }
}

variable "client_role_name" {
  description = "IAM role of the origin client; gets read access to the fsxadmin secret."
  type        = string
}

variable "vpc_id" {
  description = "Origin VPC (for the Secrets Manager endpoint)."
  type        = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_id" {
  description = "Subnet of the origin client."
  type        = string
}

variable "create_secrets_endpoint" {
  description = "Create a Secrets Manager interface endpoint in the origin VPC (~USD 0.01/h). false only if the VPC already has one."
  type        = bool
  default     = true
}

# --- the two FSx for ONTAP ---------------------------------------------------------------

variable "fsxadmin_secret_arn" {
  type = string
}

variable "fsxadmin_secret_region" {
  type = string
}

variable "origin" {
  description = "FSx for ONTAP Origin from stacks/02-fsxn."
  type = object({
    management_ip    = string
    intercluster_ips = list(string)
    svm_name         = string
    volume_name      = string
    junction_path    = optional(string, "/vol_origin")
  })
}

variable "cache" {
  description = "FSx for ONTAP Cache from stacks/02-fsxn."
  type = object({
    management_ip    = string
    intercluster_ips = list(string)
    svm_name         = string
  })
}

# --- FlexCache volume ----------------------------------------------------------------------

variable "flexcache_name" {
  type    = string
  default = "vol_cache"
}

variable "flexcache_size_gib" {
  description = "Smaller than the data set = test cache eviction; larger = warm-cache reads."
  type        = number
  default     = 500
}

variable "flexcache_junction_path" {
  type    = string
  default = "/vol_cache"
}

variable "aggregates" {
  description = "Cache aggregates. FSx for ONTAP: aggr1 (aggr2... with more HA pairs on SINGLE_AZ_2)."
  type        = list(string)
  default     = ["aggr1"]
}

# --- SMB (protocol = "smb") -------------------------------------------------------------

variable "protocol" {
  type    = string
  default = "nfs"

  validation {
    condition     = var.protocol == "nfs" || var.client_os == "windows"
    error_message = "protocol = \"smb\" runs on a Windows origin client. Re-apply 03-ec2 with protocol = \"smb\" first."
  }
}

variable "share_names" {
  description = "SMB share names: origin share on the origin SVM (-> origin volume), cache share on the cache SVM (-> FlexCache)."
  type = object({
    origin = optional(string, "origin")
    cache  = optional(string, "cache")
  })
  default = {}
}
