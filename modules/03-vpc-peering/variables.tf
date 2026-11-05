variable "name" {
  description = "Name tag of the peering connection (both sides), e.g. pedro-flexcache-perf-origin-to-cache."
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
