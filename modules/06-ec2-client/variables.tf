variable "name" {
  description = "Instance name, e.g. flexcache-perf-origin-client."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet. Put it in the same AZ as the FSxN preferred subnet to avoid cross-AZ latency in the numbers."
  type        = string
}

variable "instance_type" {
  description = "Network bandwidth matters most for the read test (c6in/m6in families are network-optimised)."
  type        = string
  default     = "c6in.2xlarge"
}

variable "ami_id" {
  description = "null = latest Amazon Linux 2023 (x86_64) from SSM public parameter."
  type        = string
  default     = null
}

variable "root_volume_size_gib" {
  type    = number
  default = 30
}

variable "key_name" {
  description = "Optional EC2 key pair. Access is via SSM Session Manager by default."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to SSH/ICMP to the instance (e.g. both VPCs)."
  type        = list(string)
  default     = []
}

variable "packages" {
  description = "dnf packages installed at boot."
  type        = list(string)
  default     = ["nfs-utils", "fio", "git", "jq", "python3", "sysstat", "iperf3"]
}

variable "additional_policy_arns" {
  description = "Extra IAM policies for the instance role (beyond SSM access)."
  type        = list(string)
  default     = []
}
