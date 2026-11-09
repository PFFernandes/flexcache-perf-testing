# EC2 client
# One Linux test client (Amazon Linux 2023) in the same private subnet as the
# FSx for ONTAP of its side. At boot it mounts the NFS paths in var.nfs_mounts
# under /mnt/fsxn/<name>. A systemd timer retries every minute, so a path that
# doesn't exist yet (the FlexCache volume before stack 04-flexcache) mounts as
# soon as it appears.
#
# Access from your Mac, with no internet, NAT or public IP in the VPC:
#   EC2 Instance Connect Endpoint   aws ec2-instance-connect ssh --instance-id <id>   (enable_eice)
#   SSM Session Manager             aws ssm start-session --target <id>              (enable_ssm)
# Both endpoints are per VPC and live in this module, so each side gets its own.
#
# Resources:
#   aws_security_group.client / .eice / .ssm_endpoints + rules
#   aws_ec2_instance_connect_endpoint.this      (enable_eice)
#   aws_vpc_endpoint.ssm["ssm" | "ssmmessages" | "ec2messages"]  (enable_ssm)
#   aws_iam_role + instance profile             AmazonSSMManagedInstanceCore
#   aws_instance.this                           IMDSv2, encrypted gp3, user_data mounts
#
# Tags: Name = <var.name>-... here, plus the Creator tag from the provider default_tags.

data "aws_region" "current" {}

data "aws_default_tags" "current" {}

data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

locals {
  ami_id = coalesce(var.ami_id, try(data.aws_ssm_parameter.al2023[0].value, null))

  ssm_services = var.enable_ssm ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    mounts = var.nfs_mounts
  })
}

# --- Security groups -----------------------------------------------------------

resource "aws_security_group" "client" {
  name        = "${var.name}-sg"
  description = "EC2 client ${var.name}: SSH from the EC2 Instance Connect Endpoint only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-sg" }
}

# NFS to FSx for ONTAP (both VPCs), HTTPS to the SSM endpoints, S3 endpoint for dnf.
resource "aws_vpc_security_group_egress_rule" "client_all" {
  security_group_id = aws_security_group.client.id
  description       = "All outbound (NFS to FSx for ONTAP, SSM endpoints, S3 endpoint)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = { Name = "${var.name}-egress-all" }
}

resource "aws_vpc_security_group_ingress_rule" "client_ssh_from_eice" {
  count = var.enable_eice ? 1 : 0

  security_group_id            = aws_security_group.client.id
  description                  = "SSH from the EC2 Instance Connect Endpoint"
  referenced_security_group_id = aws_security_group.eice[0].id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22

  tags = { Name = "${var.name}-ingress-ssh-eice" }
}

resource "aws_security_group" "eice" {
  count = var.enable_eice ? 1 : 0

  name        = "${var.name}-eice-sg"
  description = "EC2 Instance Connect Endpoint ${var.name}: SSH to the client only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-eice-sg" }
}

resource "aws_vpc_security_group_egress_rule" "eice_to_client" {
  count = var.enable_eice ? 1 : 0

  security_group_id            = aws_security_group.eice[0].id
  description                  = "SSH to the EC2 client"
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22

  tags = { Name = "${var.name}-eice-egress-ssh" }
}

resource "aws_security_group" "ssm_endpoints" {
  count = var.enable_ssm ? 1 : 0

  name        = "${var.name}-ssm-endpoints-sg"
  description = "SSM interface endpoints ${var.name}: HTTPS from the EC2 client only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-ssm-endpoints-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "ssm_from_client" {
  count = var.enable_ssm ? 1 : 0

  security_group_id            = aws_security_group.ssm_endpoints[0].id
  description                  = "HTTPS from the EC2 client"
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  tags = { Name = "${var.name}-ssm-ingress-https" }
}

# --- Access: EC2 Instance Connect Endpoint ---------------------------------------

resource "aws_ec2_instance_connect_endpoint" "this" {
  count = var.enable_eice ? 1 : 0

  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.eice[0].id]
  preserve_client_ip = false # traffic comes from the EICE, so the SG reference matches

  tags = { Name = "${var.name}-eice" }
}

# --- Access: SSM Session Manager (interface endpoints, no internet needed) --------

resource "aws_vpc_endpoint" "ssm" {
  for_each = local.ssm_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.ssm_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-${each.key}-endpoint" }
}

# --- IAM (SSM agent) ---------------------------------------------------------------

resource "aws_iam_role" "this" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.name}-role" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.this.name

  tags = { Name = "${var.name}-profile" }
}

# --- Instance ------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.client.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gib
    encrypted   = true
  }

  user_data                   = local.user_data
  user_data_replace_on_change = true # changed mounts = fresh instance

  # default_tags don't reach the root volume, so copy them (Creator) plus a Name.
  volume_tags = merge(data.aws_default_tags.current.tags, { Name = "${var.name}-root" })

  tags = { Name = var.name }

  # SSM agent needs its endpoints before it starts.
  depends_on = [aws_vpc_endpoint.ssm]
}
