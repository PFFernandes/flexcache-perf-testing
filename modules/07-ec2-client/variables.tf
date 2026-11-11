variable "name" {
  description = "Prefix of the client's supporting resources (security groups, endpoints, IAM), e.g. pedro-flexcache-perf-origin-client."
  type        = string
}

variable "instance_name" {
  description = "Name tag of the EC2 instance, e.g. pedro-origin-client."
  type        = string
}

variable "os" {
  description = "linux (Amazon Linux 2023, NFS mounts) or windows (Windows Server 2022, SMB drive mappings)."
  type        = string
  default     = "linux"

  validation {
    condition     = contains(["linux", "windows"], var.os)
    error_message = "os must be linux or windows."
  }
}

variable "hostname" {
  description = "Hostname (computer name on Windows) of the instance, e.g. origin-client."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.hostname))
    error_message = "hostname must use lowercase letters, digits and hyphens, and can't start or end with a hyphen."
  }

  validation {
    condition     = var.os == "linux" || length(var.hostname) <= 15
    error_message = "A Windows computer name has at most 15 characters."
  }
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet - the same one as the FSx for ONTAP of this side."
  type        = string
}

variable "instance_type" {
  description = "null = t3.small on Linux, t3.medium on Windows."
  type        = string
  default     = null
}

variable "architecture" {
  description = "x86_64 for Intel/AMD types (t3, m7i, c6in ...), arm64 for Graviton (t4g, c7g ...). Picks the AL2023 AMI."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }

  validation {
    condition     = var.os == "linux" || var.architecture == "x86_64"
    error_message = "The Windows client is x86_64 only."
  }
}

variable "ami_id" {
  description = "null = latest Amazon Linux 2023, or Windows Server 2022 for os = windows (SSM agent preinstalled on both)."
  type        = string
  default     = null
}

variable "root_volume_gib" {
  description = "null = 8 GiB on Linux, 50 GiB on Windows."
  type        = number
  default     = null
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

variable "smb_mappings" {
  description = "Windows only: SMB shares mapped for every user, share name => { drive letter, server }. Path = \\\\<server>\\<share name>."
  type = map(object({
    drive    = string           # e.g. "O"
    server   = string           # SMB DNS name (domain joined) or IP of the SVM
    fallback = optional(string) # used while server doesn't resolve, e.g. the SVM SMB IP
  }))
  default = {}

  validation {
    condition     = alltrue([for m in values(var.smb_mappings) : can(regex("^[D-Z]$", m.drive))])
    error_message = "Each drive must be one letter from D to Z."
  }
}

variable "ad_secret" {
  description = "Windows only: Secrets Manager secret with the AD Admin account ({ name }), in this region or replicated to it. Used for the shares and the local Administrator password."
  type = object({
    name = string
  })
  default = null

  validation {
    condition     = var.os == "linux" || var.ad_secret != null
    error_message = "A Windows client needs ad_secret (the Managed AD Admin secret from stacks/01-landing-zone)."
  }
}

variable "enable_secrets_endpoint" {
  description = "Create a Secrets Manager interface endpoint in this VPC (~USD 0.01/h). Needed by Windows clients to read ad_secret."
  type        = bool
  default     = false
}

variable "domain_join" {
  description = "Windows only: join the AWS Managed AD. The client sends queries for the domain to dns_ips (an NRPT rule, the rest still goes to the VPC DNS) and joins into ou with the ad_secret account. null = stay in a workgroup."
  type = object({
    domain_name = string       # e.g. flexcache.lab
    dns_ips     = list(string) # domain controllers
    ou          = string       # e.g. OU=Computers,OU=FLEXCACHE,DC=flexcache,DC=lab
  })
  default = null

  validation {
    condition     = var.domain_join == null || var.os == "windows"
    error_message = "domain_join is for Windows clients only."
  }
}
