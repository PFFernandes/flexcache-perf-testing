# --- Managed AD Admin password (protocol = "smb" only) ----------------------------
# Generated here and stored in Secrets Manager as <creator>-<project>/ad-admin, in
# the origin region. With a cross-region cache it is replicated to cache_region,
# so the cache client reads it through its own VPC endpoint.
# Used by: the directory (Admin account), stacks/02-fsxn (SVM domain join),
# stacks/03-ec2 (Windows local Administrator password and SMB share mapping).

resource "random_password" "ad_admin" {
  count = local.smb ? 1 : 0

  length           = 24
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 1
  override_special = "!#%*-_=+" # no quotes, backslashes or $ (PowerShell, ONTAP, shells)
}

resource "aws_secretsmanager_secret" "ad_admin" {
  count    = local.smb && var.deploy_origin ? 1 : 0
  provider = aws.origin

  name        = "${local.name_prefix}/ad-admin"
  description = "Admin account of the Managed AD ${var.ad_domain_name} (${local.name_prefix})"

  # Lab environment: delete immediately on destroy so the name can be reused.
  recovery_window_in_days = 0

  dynamic "replica" {
    for_each = var.deploy_cache && var.cache_region != var.origin_region ? [var.cache_region] : []
    content {
      region = replica.value
    }
  }

  tags = { Name = "${local.name_prefix}-ad-admin" }
}

resource "aws_secretsmanager_secret_version" "ad_admin" {
  count    = length(aws_secretsmanager_secret.ad_admin)
  provider = aws.origin

  secret_id = aws_secretsmanager_secret.ad_admin[0].id
  secret_string = jsonencode({
    username    = "Admin"
    password    = random_password.ad_admin[0].result
    domain_name = var.ad_domain_name
    short_name  = var.ad_short_name
  })
}
