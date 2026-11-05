# Read by scripts/ontap-tunnel.sh.
output "helper" {
  value = local.helper == null ? null : {
    side        = local.side
    region      = local.side == "origin" ? var.origin_region : var.cache_region
    instance_id = local.helper.instance_id
    private_ip  = local.helper.private_ip
    eice_id     = local.helper.eice_id
    os_user     = local.helper.os_user
  }
}
