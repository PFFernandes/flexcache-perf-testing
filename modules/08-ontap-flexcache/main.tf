# ONTAP FlexCache configuration, executed on the ORIGIN EC2 client
# (files/flexcache.py on Linux for NFS, files/flexcache.ps1 on Windows for SMB).
#
# The AWS FSx API has no cluster peering or FlexCache calls, so they go through
# the ONTAP REST API on the management IPs, which are private. Instead of
# reaching them from the operator machine, Terraform sends files/flexcache.py to the origin
# client with SSM Run Command (files/ssm-run.sh), and the client does:
#   1. cluster peer   Origin <-> Cache (intercluster LIFs, TCP 11104/11105)
#   2. SVM peer       svm-cache <-> svm-origin, application flexcache
#   3. FlexCache      vol_cache on svm-cache -> vol_origin on svm-origin
#   4. SMB shares     protocol = "smb" only: Origin -> vol_origin, Cache -> vol_cache
# `terraform destroy` sends the same script with "delete" (reverse order).
#
# The client reads the fsxadmin password itself from Secrets Manager, through
# the interface endpoint below (the VPC has no internet), using its instance
# role, which gets read access to that one secret here.
#
# Resources:
#   aws_security_group.secrets_endpoint + rule   HTTPS from the origin VPC
#   aws_vpc_endpoint.secretsmanager              (create_secrets_endpoint)
#   aws_iam_role_policy.read_fsxadmin            on the origin client's role
#   terraform_data.flexcache                     runs ssm-run.sh create / delete
#
# Tags: Name = <var.name>-... here, plus the Creator tag from the provider default_tags.
# ONTAP objects (peers, FlexCache) can't carry AWS tags.

data "aws_region" "current" {}

locals {
  config = merge({
    secret_arn    = var.fsxadmin_secret_arn
    secret_region = var.fsxadmin_secret_region
    origin = {
      management_ip    = var.origin.management_ip
      intercluster_ips = var.origin.intercluster_ips
      svm_name         = var.origin.svm_name
      volume_name      = var.origin.volume_name
    }
    cache = {
      management_ip    = var.cache.management_ip
      intercluster_ips = var.cache.intercluster_ips
      svm_name         = var.cache.svm_name
    }
    flexcache = {
      name          = var.flexcache_name
      size_gib      = var.flexcache_size_gib
      junction_path = var.flexcache_junction_path
      aggregates    = var.aggregates
    }
    },
    # Only added for SMB, so an existing NFS setup keeps the same hash (no rebuild).
    [for smb in(var.protocol == "smb" ? [true] : []) : {
      protocol = "smb"
      shares = {
        origin = { name = var.share_names.origin, path = var.origin.junction_path }
        cache  = { name = var.share_names.cache, path = var.flexcache_junction_path }
      }
  }]...)

  script_file = var.client_os == "windows" ? "flexcache.ps1" : "flexcache.py"
}

# --- Secrets Manager endpoint (origin VPC has no internet) -------------------------

resource "aws_security_group" "secrets_endpoint" {
  count = var.create_secrets_endpoint ? 1 : 0

  name        = "${var.name}-secretsmanager-endpoint-sg"
  description = "Secrets Manager endpoint ${var.name}: HTTPS from the origin VPC"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-secretsmanager-endpoint-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "secrets_https" {
  count = var.create_secrets_endpoint ? 1 : 0

  security_group_id = aws_security_group.secrets_endpoint[0].id
  description       = "HTTPS from the origin VPC (origin EC2 client)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = { Name = "${var.name}-secretsmanager-ingress-https" }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  count = var.create_secrets_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.secrets_endpoint[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-secretsmanager-endpoint" }
}

# --- Origin client may read the fsxadmin secret --------------------------------------

resource "aws_iam_role_policy" "read_fsxadmin" {
  name = "${var.name}-read-fsxadmin"
  role = var.client_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.fsxadmin_secret_arn
    }]
  })
}

# --- Run the configuration on the origin client ------------------------------------------

resource "terraform_data" "flexcache" {
  # Any change to the configuration deletes and recreates the FlexCache setup.
  triggers_replace = sha256(jsonencode(local.config))

  # Destroy-time provisioners may only use self, so everything they need is stored here.
  input = {
    runner      = "${path.module}/files/ssm-run.sh"
    region      = var.client_region
    instance_id = var.client_instance_id
    client_os   = var.client_os
    script_gz64 = base64gzip(file("${path.module}/files/${local.script_file}"))
    config_b64  = base64encode(jsonencode(local.config))
  }

  provisioner "local-exec" {
    command = "bash '${self.input.runner}'"
    environment = {
      ACTION      = "create"
      CLIENT_OS   = try(self.input.client_os, "linux")
      REGION      = self.input.region
      INSTANCE_ID = self.input.instance_id
      SCRIPT_GZ64 = self.input.script_gz64
      CONFIG_B64  = self.input.config_b64
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${self.input.runner}'"
    environment = {
      ACTION      = "delete"
      CLIENT_OS   = try(self.input.client_os, "linux")
      REGION      = self.input.region
      INSTANCE_ID = self.input.instance_id
      SCRIPT_GZ64 = self.input.script_gz64
      CONFIG_B64  = self.input.config_b64
    }
  }

  # The client needs the endpoint, its HTTPS rule and the permission while this runs,
  # on create and on destroy: Terraform removes them only after this resource.
  depends_on = [
    aws_vpc_endpoint.secretsmanager,
    aws_vpc_security_group_ingress_rule.secrets_https,
    aws_iam_role_policy.read_fsxadmin,
  ]
}
