# Network Origin
# The VPC on the origin side of the test: it hosts the FSx for ONTAP Origin
# (modules/04-fsxn-origin) and the origin EC2 client (modules/06-ec2-client).

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs        = length(var.azs) > 0 ? var.azs : data.aws_availability_zones.available.names
  has_public = length(var.public_subnet_cidrs) > 0
  create_nat = var.enable_nat_gateway && local.has_public

  # Added to every resource on top of the provider default_tags
  # (Project, Owner, Stack, Side, ManagedBy + any extra_tags).
  tags = merge(var.tags, { Module = "01-network-origin" })
}

# --- VPC -------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# --- Default VPC resources -------------------------------------------------
# AWS creates these with every VPC, untagged. Adopting them lets us tag them.

# No rules = deny all. Nothing here uses the default SG (FSx for ONTAP and the
# EC2 clients have their own), so it is locked down as a best practice.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-default-deny" })
}

# Main route table: unused (subnets get explicit route tables below), tagged only.
resource "aws_default_route_table" "this" {
  default_route_table_id = aws_vpc.this.default_route_table_id
  tags                   = merge(local.tags, { Name = "${var.name}-main-unused" })
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

  tags = merge(local.tags, { Name = "${var.name}-default" })
}

# --- Subnets ---------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index % length(local.azs)]

  tags = merge(local.tags, {
    Name = "${var.name}-private-${local.azs[count.index % length(local.azs)]}"
    Tier = "private"
  })
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index % length(local.azs)]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${var.name}-public-${local.azs[count.index % length(local.azs)]}"
    Tier = "public"
  })
}

# --- Internet access (optional) -------------------------------------------

resource "aws_internet_gateway" "this" {
  count  = local.has_public ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

resource "aws_route_table" "public" {
  count  = local.has_public ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public" })
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
  tags   = merge(local.tags, { Name = "${var.name}-nat" })
}

resource "aws_nat_gateway" "this" {
  count         = local.create_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.tags, { Name = "${var.name}-nat" })

  depends_on = [aws_internet_gateway.this]
}

# --- Private routing -------------------------------------------------------
# One route table for all private subnets keeps peering routes and the
# FSxN Multi-AZ route_table_ids simple.

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-private" })
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
  tags              = merge(local.tags, { Name = "${var.name}-s3" })
}
