# Works for both same-region and cross-region peering (same account).
# The requester side lives in aws.requester, the accepter side in aws.accepter.

data "aws_region" "requester" {
  provider = aws.requester
}

data "aws_region" "accepter" {
  provider = aws.accepter
}

data "aws_caller_identity" "accepter" {
  provider = aws.accepter
}

locals {
  cross_region = data.aws_region.requester.region != data.aws_region.accepter.region

  # Added on top of the provider default_tags. PeeringRole (not Side) so the
  # provider's Side tag (origin / cache / bastion) is kept.
  tags = merge(var.tags, { Module = "03-vpc-peering", Name = var.name })
}

resource "aws_vpc_peering_connection" "this" {
  provider = aws.requester

  vpc_id        = var.requester_vpc_id
  peer_vpc_id   = var.accepter_vpc_id
  peer_owner_id = data.aws_caller_identity.accepter.account_id
  peer_region   = local.cross_region ? data.aws_region.accepter.region : null
  auto_accept   = false # accepted explicitly below (required for cross-region)

  tags = merge(local.tags, { PeeringRole = "requester" })
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider = aws.accepter

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = merge(local.tags, { PeeringRole = "accepter" })
}

# Routes reference the accepter resource so they are only created once the
# peering is active.

resource "aws_route" "requester_to_accepter" {
  provider = aws.requester
  count    = length(var.requester_route_table_ids)

  route_table_id            = var.requester_route_table_ids[count.index]
  destination_cidr_block    = var.accepter_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}

resource "aws_route" "accepter_to_requester" {
  provider = aws.accepter
  count    = length(var.accepter_route_table_ids)

  route_table_id            = var.accepter_route_table_ids[count.index]
  destination_cidr_block    = var.requester_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}
