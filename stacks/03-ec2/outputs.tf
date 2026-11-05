# Enabled once modules/06-ec2-client exposes its outputs (layer 3 implementation).
#
# origin_client is also the SSM tunnel host for scripts/ontap-tunnel.sh (stack 04).
#
# output "origin_client" {
#   value = {
#     region      = var.origin_region
#     instance_id = module.ec2_origin.instance_id
#     private_ip  = module.ec2_origin.private_ip
#     connect     = module.ec2_origin.ssm_connect_command
#   }
# }
#
# output "cache_client" {
#   value = var.enable_cache_ec2 ? {
#     instance_id = module.ec2_cache[0].instance_id
#     private_ip  = module.ec2_cache[0].private_ip
#     connect     = module.ec2_cache[0].ssm_connect_command
#   } : null
# }
