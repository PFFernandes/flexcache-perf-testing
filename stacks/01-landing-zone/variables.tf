# --- common (from ../../common.tfvars) --------------------------------------

variable "project" {
  type = string
}

variable "creator" {
  description = "Value of the Creator tag, the only tag put on every AWS resource."
  type        = string
}

variable "origin_region" {
  type = string
}

variable "cache_region" {
  type = string
}

# --- origin VPC ------------------------------------------------------------

variable "origin_vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "origin_private_subnet_cidrs" {
  description = "One per AZ. Single-AZ FSxN uses the first, Multi-AZ the first two."
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "origin_public_subnet_cidrs" {
  description = "Only used for the NAT gateway. [] = no internet access from the VPC."
  type        = list(string)
  default     = ["10.10.101.0/24"]
}

variable "origin_nat_gateway" {
  type    = bool
  default = true
}

# --- cache VPC -------------------------------------------------------------

variable "cache_vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "cache_private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "cache_public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.101.0/24"]
}

variable "cache_nat_gateway" {
  type    = bool
  default = true
}
