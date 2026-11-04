# --- common (from ../../common.tfvars) --------------------------------------

variable "project" {
  type = string
}

variable "owner" {
  type = string
}

variable "origin_region" {
  type = string
}

variable "cache_region" {
  type = string
}

# --- bastion (the host you run this automation from) ------------------------

variable "bastion_vpc_id" {
  description = "VPC of your manually created bastion host. When set, it is peered with both the origin and the cache VPC, so the bastion can reach the FSxN management IPs (stack 04) and the EC2 clients. null = no bastion peering."
  type        = string
  default     = null
}

variable "bastion_region" {
  description = "Region of the bastion VPC. null = origin_region."
  type        = string
  default     = null
}

variable "bastion_route_table_ids" {
  description = "Bastion VPC route tables that get routes to the origin and cache CIDRs. null = all route tables in the bastion VPC."
  type        = list(string)
  default     = null
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
