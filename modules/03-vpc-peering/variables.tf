variable "name" {
  description = "Name tag for the peering connection."
  type        = string
}

variable "requester_vpc_id" {
  type = string
}

variable "requester_cidr" {
  type = string
}

variable "requester_route_table_ids" {
  description = "Route tables in the requester VPC that get a route to the accepter CIDR."
  type        = list(string)
}

variable "accepter_vpc_id" {
  type = string
}

variable "accepter_cidr" {
  type = string
}

variable "accepter_route_table_ids" {
  description = "Route tables in the accepter VPC that get a route to the requester CIDR."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
