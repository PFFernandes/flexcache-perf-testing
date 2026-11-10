# Contract consumed by 02-fsxn via terraform_remote_state.
# Keep these names stable; add fields rather than renaming them.

output "origin" {
  description = "null when deploy_origin = false."
  value = var.deploy_origin ? {
    region                  = var.origin_region
    vpc_id                  = module.origin_network[0].vpc_id
    vpc_cidr                = module.origin_network[0].vpc_cidr
    azs                     = module.origin_network[0].azs
    private_subnet_ids      = module.origin_network[0].private_subnet_ids
    public_subnet_ids       = module.origin_network[0].public_subnet_ids
    private_route_table_ids = module.origin_network[0].private_route_table_ids
  } : null
}

output "cache" {
  description = "null when deploy_cache = false."
  value = var.deploy_cache ? {
    region                  = var.cache_region
    vpc_id                  = module.cache_network[0].vpc_id
    vpc_cidr                = module.cache_network[0].vpc_cidr
    azs                     = module.cache_network[0].azs
    private_subnet_ids      = module.cache_network[0].private_subnet_ids
    public_subnet_ids       = module.cache_network[0].public_subnet_ids
    private_route_table_ids = module.cache_network[0].private_route_table_ids
  } : null
}

output "peering_connection_id" {
  description = "null unless both sides are deployed."
  value       = try(module.peering[0].peering_connection_id, null)
}

output "cross_region" {
  value = var.origin_region != var.cache_region
}

output "protocol" {
  value = var.protocol
}

output "directory" {
  description = "AWS Managed Microsoft AD. null unless protocol = \"smb\"."
  value = length(module.directory) == 0 ? null : {
    region           = var.origin_region
    directory_id     = module.directory[0].directory_id
    domain_name      = module.directory[0].domain_name
    short_name       = module.directory[0].short_name
    dns_ips          = module.directory[0].dns_ips
    computers_ou     = module.directory[0].computers_ou
    fsx_admins_group = module.directory[0].fsx_admins_group
    admin_secret = {
      name    = aws_secretsmanager_secret.ad_admin[0].name
      arn     = aws_secretsmanager_secret.ad_admin[0].arn
      region  = var.origin_region
      regions = distinct(concat([var.origin_region], [for r in aws_secretsmanager_secret.ad_admin[0].replica : r.region]))
    }
  }
}
