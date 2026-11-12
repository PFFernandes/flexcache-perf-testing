variable "name" {
  description = "Name tag, e.g. pedro-flexcache-perf-vol_bench."
  type        = string
}

variable "lab" {
  description = "Lab name, tagged on the volume and its final backup."
  type        = string
}

variable "file_system_id" {
  description = "FSx for ONTAP file system that holds the volume (origin by default)."
  type        = string
}

variable "volume_name" {
  type    = string
  default = "vol_bench"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]{0,202}$", var.volume_name))
    error_message = "volume_name: letters, digits and underscores, starting with a letter or underscore (ONTAP volume name)."
  }
}

variable "junction_path" {
  type    = string
  default = "/vol_bench"
}

variable "size_gib" {
  description = "Volume size. Telemetry is a few hundred MB per client per day before compression."
  type        = number
  default     = 100

  validation {
    condition     = var.size_gib >= 1
    error_message = "size_gib must be at least 1."
  }
}

variable "snapshot_policy" {
  description = "ONTAP snapshot policy: default keeps hourly, daily and weekly snapshots (protection against mistakes)."
  type        = string
  default     = "default"
}

variable "skip_final_backup" {
  description = "false (default) = FSx keeps a final backup when the volume is deleted. Set true and apply BEFORE destroying to discard the results."
  type        = bool
  default     = false
}
