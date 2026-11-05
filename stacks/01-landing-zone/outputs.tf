# Contract consumed by 02-fsxn and 03-ec2 via terraform_remote_state.
# Keep these names stable; add fields rather than renaming them.

output "origin" {
  value = {
    region                  = var.origin_region
    vpc_id                  = module.origin_network.vpc_id
    vpc_cidr                = module.origin_network.vpc_cidr
    azs                     = module.origin_network.azs
    private_subnet_ids      = module.origin_network.private_subnet_ids
    public_subnet_ids       = module.origin_network.public_subnet_ids
    private_route_table_ids = module.origin_network.private_route_table_ids
  }
}

output "cache" {
  value = {
    region                  = var.cache_region
    vpc_id                  = module.cache_network.vpc_id
    vpc_cidr                = module.cache_network.vpc_cidr
    azs                     = module.cache_network.azs
    private_subnet_ids      = module.cache_network.private_subnet_ids
    public_subnet_ids       = module.cache_network.public_subnet_ids
    private_route_table_ids = module.cache_network.private_route_table_ids
  }
}

output "peering_connection_id" {
  value = module.peering.peering_connection_id
}

output "cross_region" {
  value = module.peering.cross_region
}
