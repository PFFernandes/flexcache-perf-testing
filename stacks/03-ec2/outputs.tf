output "origin_client" {
  description = "null when the origin client is not deployed. Also the host that stacks/04-flexcache runs the ONTAP configuration on."
  value = length(module.ec2_origin) == 0 ? null : {
    region       = var.origin_region
    instance_id  = module.ec2_origin[0].instance_id
    role_name    = module.ec2_origin[0].role_name
    ssm_enabled  = module.ec2_origin[0].ssm_enabled
    private_ip   = module.ec2_origin[0].private_ip
    mounts       = module.ec2_origin[0].mounts
    connect_eice = module.ec2_origin[0].connect_eice
    connect_ssm  = module.ec2_origin[0].connect_ssm
  }
}

output "cache_client" {
  description = "null when the cache client is not deployed."
  value = length(module.ec2_cache) == 0 ? null : {
    region       = var.cache_region
    instance_id  = module.ec2_cache[0].instance_id
    role_name    = module.ec2_cache[0].role_name
    ssm_enabled  = module.ec2_cache[0].ssm_enabled
    private_ip   = module.ec2_cache[0].private_ip
    mounts       = module.ec2_cache[0].mounts
    connect_eice = module.ec2_cache[0].connect_eice
    connect_ssm  = module.ec2_cache[0].connect_ssm
  }
}
