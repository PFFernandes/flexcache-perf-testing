# EC2 client
# One test client in the same private subnet as the FSx for ONTAP of its side.
#   os = "linux"   (protocol nfs): Amazon Linux 2023. Mounts var.nfs_mounts under
#                  /mnt/fsxn/<name>; a systemd timer retries every minute.
#   os = "windows" (protocol smb): Windows Server 2022. Maps var.smb_mappings to
#                  drive letters for every user; a scheduled task retries every
#                  minute. The local Administrator password is set from var.ad_secret.
#                  With var.domain_join it also joins the AWS Managed AD (after the rename).
# The retries matter because the FlexCache (and its share) only appear in stack 04.
#
# Access from your Mac, with no internet, NAT or public IP in the VPC:
#   EC2 Instance Connect Endpoint   SSH (Linux) or an RDP tunnel (Windows)          (enable_eice)
#   SSM Session Manager             aws ssm start-session --target <id>              (enable_ssm)
# Both endpoints are per VPC and live in this module, so each side gets its own.
#
# Resources:
#   aws_security_group.client / .eice / .ssm_endpoints + rules
#   aws_ec2_instance_connect_endpoint.this      (enable_eice)
#   aws_vpc_endpoint.ssm["ssm" | "ssmmessages" | "ec2messages"]  (enable_ssm)
#   aws_vpc_endpoint.secretsmanager             (enable_secrets_endpoint, Windows)
#   aws_iam_role + instance profile             AmazonSSMManagedInstanceCore (+ read var.ad_secret)
#   aws_instance.this                           IMDSv2, encrypted gp3, user_data mounts or maps
#
# Tags: Name = <var.name>-... here, plus the Creator tag from the provider default_tags.

data "aws_region" "current" {}

data "aws_default_tags" "current" {}

data "aws_ssm_parameter" "ami" {
  count = var.ami_id == null ? 1 : 0
  name = (local.windows
    ? "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
  : "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}")
}

locals {
  windows = var.os == "windows"

  ami_id          = coalesce(var.ami_id, try(data.aws_ssm_parameter.ami[0].value, null))
  instance_type   = coalesce(var.instance_type, local.windows ? "t3.medium" : "t3.small")
  root_volume_gib = coalesce(var.root_volume_gib, local.windows ? 50 : 8)

  # What the Instance Connect Endpoint may open: SSH on Linux, RDP on Windows.
  access_port = local.windows ? 3389 : 22
  access_name = local.windows ? "rdp" : "ssh"

  ssm_services = var.enable_ssm ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])

  user_data = (local.windows
    ? templatefile("${path.module}/user_data.ps1.tftpl", {
      hostname    = var.hostname
      mappings    = var.smb_mappings
      secret_name = try(var.ad_secret.name, "")
      region      = data.aws_region.current.region
      domain_join = var.domain_join
    })
    : templatefile("${path.module}/user_data.sh.tftpl", {
      mounts   = var.nfs_mounts
      hostname = var.hostname
  }))
}

# --- Security groups -----------------------------------------------------------

resource "aws_security_group" "client" {
  name        = "${var.name}-sg"
  description = "EC2 client ${var.name}: ${upper(local.access_name)} from the EC2 Instance Connect Endpoint only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-sg" }
}

# NFS/SMB to FSx for ONTAP (both VPCs), AD, HTTPS to the endpoints, S3 endpoint for dnf.
resource "aws_vpc_security_group_egress_rule" "client_all" {
  security_group_id = aws_security_group.client.id
  description       = "All outbound (NFS or SMB to FSx for ONTAP, AD, endpoints, S3 endpoint)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = { Name = "${var.name}-egress-all" }
}

resource "aws_vpc_security_group_ingress_rule" "client_ssh_from_eice" {
  count = var.enable_eice ? 1 : 0

  security_group_id            = aws_security_group.client.id
  description                  = "${upper(local.access_name)} from the EC2 Instance Connect Endpoint"
  referenced_security_group_id = aws_security_group.eice[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.access_port
  to_port                      = local.access_port

  tags = { Name = "${var.name}-ingress-${local.access_name}-eice" }
}

resource "aws_security_group" "eice" {
  count = var.enable_eice ? 1 : 0

  name        = "${var.name}-eice-sg"
  description = "EC2 Instance Connect Endpoint ${var.name}: ${upper(local.access_name)} to the client only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-eice-sg" }
}

resource "aws_vpc_security_group_egress_rule" "eice_to_client" {
  count = var.enable_eice ? 1 : 0

  security_group_id            = aws_security_group.eice[0].id
  description                  = "${upper(local.access_name)} to the EC2 client"
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = local.access_port
  to_port                      = local.access_port

  tags = { Name = "${var.name}-eice-egress-${local.access_name}" }
}

# Shared by the SSM endpoints and the Secrets Manager endpoint.
resource "aws_security_group" "ssm_endpoints" {
  count = var.enable_ssm || var.enable_secrets_endpoint ? 1 : 0

  name        = "${var.name}-ssm-endpoints-sg"
  description = "Interface endpoints ${var.name}: HTTPS from the EC2 client only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-ssm-endpoints-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "ssm_from_client" {
  count = length(aws_security_group.ssm_endpoints)

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

# --- Secrets Manager endpoint (Windows: reads the AD Admin secret at boot) --------------

resource "aws_vpc_endpoint" "secretsmanager" {
  count = var.enable_secrets_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.ssm_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-secretsmanager-endpoint" }
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

# Read the AD Admin secret (Windows clients). The ARN pattern covers its replica regions.
resource "aws_iam_role_policy" "read_ad_admin" {
  count = var.ad_secret == null ? 0 : 1

  name = "${var.name}-read-ad-admin"
  role = aws_iam_role.this.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:*:*:secret:${var.ad_secret.name}-*"
    }]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.this.name

  tags = { Name = "${var.name}-profile" }
}

# --- Instance ------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = local.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.client.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = local.root_volume_gib
    encrypted   = true
  }

  user_data                   = local.user_data
  user_data_replace_on_change = true # changed mounts, shares or hostname = fresh instance

  # default_tags don't reach the root volume, so copy them (Creator) plus a Name.
  volume_tags = merge(data.aws_default_tags.current.tags, { Name = "${var.instance_name}-root" })

  tags = { Name = var.instance_name }

  # The SSM agent needs its endpoints before it starts; Windows reads its secret at boot.
  depends_on = [aws_vpc_endpoint.ssm, aws_vpc_endpoint.secretsmanager, aws_iam_role_policy.read_ad_admin]
}
