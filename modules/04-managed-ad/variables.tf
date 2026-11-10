variable "name" {
  description = "Name prefix, e.g. pedro-flexcache-perf (the directory is <prefix>-ad)."
  type        = string
}

variable "domain_name" {
  description = "Fully qualified domain name, e.g. flexcache.lab."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a fully qualified name in lowercase, e.g. flexcache.lab."
  }
}

variable "short_name" {
  description = "NetBIOS name of the domain, up to 15 characters, e.g. FLEXCACHE."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$", var.short_name))
    error_message = "short_name must be 1-15 letters, digits or hyphens, e.g. FLEXCACHE."
  }
}

variable "edition" {
  description = "Standard (cheaper, enough for this lab) or Enterprise."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Enterprise"], var.edition)
    error_message = "edition must be Standard or Enterprise."
  }
}

variable "admin_password" {
  description = "Password of the directory's Admin account. Generated in stacks/01-landing-zone."
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Exactly two subnets, in different AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 2
    error_message = "AWS Managed Microsoft AD needs exactly two subnets in different AZs."
  }
}

variable "peer_cidrs" {
  description = "CIDRs of peered VPCs that must reach the domain controllers (the cache VPC)."
  type        = list(string)
  default     = []
}
