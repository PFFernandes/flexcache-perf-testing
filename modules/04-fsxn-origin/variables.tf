variable "name" {
  description = "FSx for ONTAP Origin file system name, e.g. flexcache-perf-origin."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the FSxN security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets. Single-AZ uses the first one, Multi-AZ the first two (in different AZs)."
  type        = list(string)

  validation {
    condition     = !startswith(var.deployment_type, "MULTI_AZ") || length(var.subnet_ids) >= 2
    error_message = "Multi-AZ needs subnets in two AZs: set origin_azs = [\"a\", \"b\"] in common.tfvars and apply 01-landing-zone first."
  }
}

variable "route_table_ids" {
  description = "Multi-AZ only: route tables that get the floating endpoint IP routes."
  type        = list(string)
  default     = []
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the file system (local VPC + peer VPC: NFS clients, intercluster/FlexCache, ONTAP REST API)."
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

variable "automatic_backup_retention_days" {
  description = "Daily automatic backups, kept this many days. 0 = off (default, lab data)."
  type        = number
  default     = 0
}

variable "fsxadmin_password" {
  description = "fsxadmin password. Generated once by stacks/02-fsxn and shared with the FSx for ONTAP Cache."
  type        = string
  sensitive   = true
  nullable    = false
}

variable "svm_name" {
  description = "Name of the SVM created on the FSx for ONTAP Origin."
  type        = string
  default     = "svm_origin"
}

variable "volumes" {
  description = "Origin volumes (hold the test data set; the FlexCache on the FSx for ONTAP Cache points at them). FlexGroup by default."
  type = map(object({
    size_gib                   = number
    junction_path              = string
    volume_style               = optional(string, "FLEXGROUP") # FLEXGROUP | FLEXVOL
    constituents_per_aggregate = optional(number, null)        # FlexGroup only; null = AWS default (8 per aggregate)
    aggregates                 = optional(list(string), null)  # FlexGroup only; null = AWS default (aggr1)
    security_style             = optional(string, "UNIX")
    tiering_policy             = optional(string, "NONE") # keep test data on SSD
    storage_efficiency_enabled = optional(bool, true)     # dedupe + compression + compaction
    snapshot_policy            = optional(string, "none")
  }))
  default = {}

  validation {
    condition     = alltrue([for v in values(var.volumes) : contains(["FLEXGROUP", "FLEXVOL"], v.volume_style)])
    error_message = "volume_style must be FLEXGROUP or FLEXVOL."
  }

  # FSx for ONTAP needs at least 100 GiB per FlexGroup constituent.
  validation {
    condition = alltrue([for v in values(var.volumes) :
      v.volume_style != "FLEXGROUP" ||
      v.size_gib >= 100 * coalesce(v.constituents_per_aggregate, 8) * max(1, length(coalesce(v.aggregates, ["aggr1"])))
    ])
    error_message = "A FlexGroup needs at least 100 GiB per constituent (default 8 per aggregate = 800 GiB). Increase size_gib or lower constituents_per_aggregate."
  }
}
