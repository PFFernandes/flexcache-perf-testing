variable "name" {
  description = "File system name, e.g. flexcache-perf-origin."
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
  default     = "SINGLE_AZ_2"

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
  description = "MBps per HA pair. Gen2 (…_2): 384/768/1536/3072/6144. Gen1 (…_1): 128-4096. 1536 is valid on Gen2 at any HA-pair count."
  type        = number
  default     = 1536
}

variable "ha_pairs" {
  description = "Number of HA pairs (scale-out only on SINGLE_AZ_2)."
  type        = number
  default     = 1
}

variable "endpoint_ip_address_range" {
  description = "Multi-AZ only: range for floating endpoint IPs. null = AWS default."
  type        = string
  default     = null
}

variable "svm_name" {
  description = "Name of the SVM created on this file system."
  type        = string
}

variable "volumes" {
  description = "Regular FlexVol volumes to create (origin side). The FlexCache volume is NOT created here; stacks/04-flexcache creates it through the ONTAP API."
  type = map(object({
    size_gib                   = number
    junction_path              = string
    security_style             = optional(string, "UNIX")
    tiering_policy             = optional(string, "NONE") # keep test data on SSD
    storage_efficiency_enabled = optional(bool, false)    # off = cleaner perf numbers
    snapshot_policy            = optional(string, "none")
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
