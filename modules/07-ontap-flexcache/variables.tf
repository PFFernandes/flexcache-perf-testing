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
