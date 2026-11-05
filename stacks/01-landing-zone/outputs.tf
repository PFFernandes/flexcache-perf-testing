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
