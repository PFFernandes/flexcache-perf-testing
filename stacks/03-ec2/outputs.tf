# Enabled once modules/06-ec2-client exposes its outputs (layer 3 implementation).
#
# origin_client is also the SSM tunnel host for scripts/ontap-tunnel.sh (stack 04).
#
# output "origin_client" {
#   value = {
#     region      = var.origin_region
#     instance_id = module.ec2_origin[0].instance_id
#     private_ip  = module.ec2_origin[0].private_ip
#     connect     = module.ec2_origin[0].ssm_connect_command
#   } (null when deploy_origin = false)
# }
#
# output "cache_client" {
#   value = length(module.ec2_cache) > 0 ? {
#     instance_id = module.ec2_cache[0].instance_id
#     private_ip  = module.ec2_cache[0].private_ip
#     connect     = module.ec2_cache[0].ssm_connect_command
#   } : null
# }
