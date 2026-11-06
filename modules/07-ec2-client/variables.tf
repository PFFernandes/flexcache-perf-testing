variable "name" {
  description = "Instance name and prefix of its resources, e.g. pedro-flexcache-perf-origin-client."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet - the same one as the FSx for ONTAP of this side."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "architecture" {
  description = "x86_64 for Intel/AMD types (t3, m7i, c6in ...), arm64 for Graviton (t4g, c7g ...). Picks the AL2023 AMI."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "ami_id" {
  description = "null = latest Amazon Linux 2023 (SSM agent and EC2 Instance Connect preinstalled)."
  type        = string
  default     = null
}

variable "root_volume_gib" {
  type    = number
  default = 8
}

variable "enable_eice" {
  description = "Create an EC2 Instance Connect Endpoint in this VPC (free) and allow SSH from it."
  type        = bool
  default     = true
}

variable "enable_ssm" {
  description = "Create the ssm, ssmmessages and ec2messages interface endpoints in this VPC (about USD 0.01/h each) for SSM Session Manager."
  type        = bool
  default     = true
}

variable "nfs_mounts" {
  description = "NFS paths to mount at /mnt/fsxn/<key>: server = SVM NFS IP, export = junction path."
  type = map(object({
    server  = string
    export  = string
    options = optional(string, "vers=3,nconnect=8,hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576")
  }))
  default = {}
}
