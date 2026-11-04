# Enabled once modules/05-ec2-client exposes its outputs (layer 3 implementation).
#
# output "origin_client" {
#   value = {
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
