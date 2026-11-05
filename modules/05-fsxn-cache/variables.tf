variable "name" {
  description = "FSx for ONTAP Cache file system name, e.g. flexcache-perf-cache."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the FSxN security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets. Single-AZ uses the first one, Multi-AZ the first two."
  type        = list(string)
}

variable "route_table_ids" {
  description = "Multi-AZ only: route tables that get the floating endpoint IP routes."
  type        = list(string)
  default     = []
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the file system (local VPC + peer VPC for intercluster/FlexCache + bastion VPC for the ONTAP REST API)."
  type        = list(string)
}

variable "deployment_type" {
  description = "SINGLE_AZ_1 | SINGLE_AZ_2 | MULTI_AZ_1 | MULTI_AZ_2. Single-AZ is recommended for this test: its management endpoint is reachable over VPC peering."
  type        = string
  default     = "SINGLE_AZ_1"

  validation {
    condition     = contains(["SINGLE_AZ_1", "SINGLE_AZ_2", "MULTI_AZ_1", "MULTI_AZ_2"], var.deployment_type)
    error_message = "deployment_type must be SINGLE_AZ_1, SINGLE_AZ_2, MULTI_AZ_1 or MULTI_AZ_2."
  }
}

variable "storage_capacity_gib" {
  description = "SSD capacity in GiB (min 1024 per HA pair)."
  type        = number
  default     = 1024
}

variable "throughput_capacity_per_ha_pair" {
  description = "MBps per HA pair. Gen1 (…_1): 128/256/512/1024/2048/4096. Gen2 (…_2): 384/768/1536/3072/6144 (SINGLE_AZ_2 with >1 HA pair: 1536/3072/6144)."
  type        = number
  default     = 128

  validation {
    condition = (
      !endswith(var.deployment_type, "_1") ||
      contains([128, 256, 512, 1024, 2048, 4096], var.throughput_capacity_per_ha_pair)
    )
    error_message = "Gen1 deployment types (SINGLE_AZ_1, MULTI_AZ_1) support 128, 256, 512, 1024, 2048 or 4096 MBps."
  }
}

variable "ha_pairs" {
  description = "Number of HA pairs (scale-out only on SINGLE_AZ_2)."
  type        = number
  default     = 1

  validation {
    condition     = var.deployment_type == "SINGLE_AZ_2" || var.ha_pairs == 1
    error_message = "Only SINGLE_AZ_2 supports more than one HA pair."
  }
}

variable "endpoint_ip_address_range" {
  description = "Multi-AZ only: range for floating endpoint IPs. null = AWS default."
  type        = string
  default     = null
}

variable "fsxadmin_password" {
  description = "fsxadmin password. Generated once by stacks/02-fsxn and shared with the FSx for ONTAP Origin."
  type        = string
  sensitive   = true
  nullable    = false
}

variable "svm_name" {
  description = "Name of the SVM created on the FSx for ONTAP Cache (the FlexCache volume lives in it)."
  type        = string
  default     = "svm_cache"
}
