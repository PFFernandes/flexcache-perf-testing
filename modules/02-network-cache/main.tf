# Network Cache
# The VPC on the cache side of the test: it hosts the FSx for ONTAP Cache
# (modules/05-fsxn-cache) and the cache EC2 client (modules/06-ec2-client).

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs        = length(var.azs) > 0 ? var.azs : data.aws_availability_zones.available.names
  has_public = length(var.public_subnet_cidrs) > 0
  create_nat = var.enable_nat_gateway && local.has_public
}

# --- VPC -------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# --- Default VPC resources -------------------------------------------------
# AWS creates these with every VPC, untagged. Adopting them lets the provider
# default_tags put the Creator tag on them.

# No rules = deny all. Nothing here uses the default SG (FSx for ONTAP and the
# EC2 clients have their own), so it is locked down as a best practice.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
}

# Main route table: unused (subnets get explicit route tables below), adopted only for the Creator tag.
resource "aws_default_route_table" "this" {
  default_route_table_id = aws_vpc.this.default_route_table_id
}

# Same allow-all rules AWS puts on a new default NACL; security is enforced by security groups.
resource "aws_default_network_acl" "this" {
  default_network_acl_id = aws_vpc.this.default_network_acl_id
  subnet_ids             = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)

  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

# --- Subnets ---------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index % length(local.azs)]
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index % length(local.azs)]
  map_public_ip_on_launch = false
}

# --- Internet access (optional) -------------------------------------------

resource "aws_internet_gateway" "this" {
  count  = local.has_public ? 1 : 0
  vpc_id = aws_vpc.this.id
}

resource "aws_route_table" "public" {
  count  = local.has_public ? 1 : 0
  vpc_id = aws_vpc.this.id
}

resource "aws_route" "public_default" {
  count                  = local.has_public ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count  = local.create_nat ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  count         = local.create_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.this]
}

# --- Private routing -------------------------------------------------------
# One route table for all private subnets keeps peering routes and the
# FSxN Multi-AZ route_table_ids simple.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
}

resource "aws_route" "private_default" {
  count                  = local.create_nat ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- S3 gateway endpoint (free) -------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  count             = var.enable_s3_gateway_endpoint ? 1 : 0
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.private.id], aws_route_table.public[*].id)
}
