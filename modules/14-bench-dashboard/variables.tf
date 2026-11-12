variable "dashboard_name" {
  description = "Dashboard name: letters, digits, - and _ only."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,255}$", var.dashboard_name))
    error_message = "dashboard_name may only contain letters, digits, - and _."
  }
}

variable "lab" {
  description = "Lab name: the Lab dimension of the bench metrics."
  type        = string
}

variable "namespace" {
  type    = string
  default = "FlexCacheBench"
}

variable "sides" {
  description = "Per side: region, FSx for ONTAP file system ID and client instance ID (null when not deployed)."
  type = map(object({
    region         = string
    file_system_id = optional(string)
    instance_id    = optional(string)
  }))
}

variable "results_volume_id" {
  description = "vol_bench, mentioned in the header so its traffic can be told apart."
  type        = string
  default     = null
}
