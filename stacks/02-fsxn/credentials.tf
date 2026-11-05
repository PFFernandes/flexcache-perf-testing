# --- fsxadmin password (shared) ----------------------------------------------
# One password for BOTH FSx for ONTAP file systems (Origin and Cache), generated
# here once and passed to both modules. It is stored in a single Secrets Manager
# secret in the origin region; stacks/04-flexcache reads it from there for both
# ONTAP connections. Nothing password-related lives in tfvars or Git.
#
# Generated whichever side is deployed (deploy_origin / deploy_cache), so adding
# the other side later reuses the same password.

resource "random_password" "fsxadmin" {
  length           = 24
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 1
  override_special = "!#%*-_=+" # avoid quotes/backslashes/$ that break ONTAP CLI and shells
}

resource "aws_secretsmanager_secret" "fsxadmin" {
  provider = aws.origin

  name        = "${local.name_prefix}/fsxadmin"
  description = "fsxadmin credentials shared by the FSx for ONTAP Origin and FSx for ONTAP Cache (${local.name_prefix})"

  # Lab environment: delete immediately on destroy so the same name can be
  # recreated right away (default would keep it for 30 days).
  recovery_window_in_days = 0

  tags = { Name = "${local.name_prefix}-fsxadmin" }
}

resource "aws_secretsmanager_secret_version" "fsxadmin" {
  provider = aws.origin

  secret_id = aws_secretsmanager_secret.fsxadmin.id
  secret_string = jsonencode({
    username = "fsxadmin"
    password = random_password.fsxadmin.result
  })
}
