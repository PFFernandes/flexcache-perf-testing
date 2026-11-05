# Helper EC2
# A small private instance that is only a network hop: from your Mac, an SSH
# tunnel through the EC2 Instance Connect Endpoint (EICE) reaches it, and SSH
# port forwards (-L) carry the ONTAP REST API traffic of stack 04-flexcache on
# to the FSx for ONTAP management IPs. It runs no ONTAP commands itself.
#
# No public IP, no internet gateway, no NAT: EICE is the only way in, and only
# on TCP 22. Software installs (dnf) use the VPC's S3 gateway endpoint.
#
# Resources:
#   aws_security_group.eice / .helper         EICE -> helper on 22, helper -> anywhere in the VPCs
#   aws_ec2_instance_connect_endpoint.this    one per VPC, free
#   aws_instance.this                         Amazon Linux 2023 (arm64), IMDSv2, encrypted gp3
#
# Tags: Name = <var.name>-... here, plus the Creator tag from the provider default_tags.

data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

data "aws_default_tags" "current" {}

locals {
  ami_id = coalesce(var.ami_id, try(data.aws_ssm_parameter.al2023[0].value, null))
}

# --- Security groups -----------------------------------------------------------

resource "aws_security_group" "eice" {
  name        = "${var.name}-eice-sg"
  description = "EC2 Instance Connect Endpoint ${var.name}: SSH to the helper only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-eice-sg" }
}

resource "aws_vpc_security_group_egress_rule" "eice_to_helper" {
  security_group_id            = aws_security_group.eice.id
  description                  = "SSH to the helper instance"
  referenced_security_group_id = aws_security_group.helper.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22

  tags = { Name = "${var.name}-eice-egress-ssh" }
}

resource "aws_security_group" "helper" {
  name        = "${var.name}-sg"
  description = "Helper ${var.name}: SSH from the EICE only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "helper_ssh_from_eice" {
  security_group_id            = aws_security_group.helper.id
  description                  = "SSH from the EC2 Instance Connect Endpoint"
  referenced_security_group_id = aws_security_group.eice.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22

  tags = { Name = "${var.name}-ingress-ssh-eice" }
}

# FSx for ONTAP management (443/22) in both VPCs, plus the S3 gateway endpoint for dnf.
resource "aws_vpc_security_group_egress_rule" "helper_all" {
  security_group_id = aws_security_group.helper.id
  description       = "All outbound (FSx for ONTAP management over the peering, S3 endpoint)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = { Name = "${var.name}-egress-all" }
}

# --- EC2 Instance Connect Endpoint --------------------------------------------

resource "aws_ec2_instance_connect_endpoint" "this" {
  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.eice.id]
  preserve_client_ip = false # traffic comes from the EICE, so the SG reference above matches

  tags = { Name = "${var.name}-eice" }
}

# --- Instance --------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.helper.id]
  associate_public_ip_address = false

  # Access is EC2 Instance Connect: a short-lived key is pushed per session, so no key pair.
  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gib
    encrypted   = true
  }

  # default_tags don't reach the root volume, so copy them (Creator) plus a Name.
  volume_tags = merge(data.aws_default_tags.current.tags, { Name = "${var.name}-root" })

  tags = { Name = var.name }
}
