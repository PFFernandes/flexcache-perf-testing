# FSx for ONTAP Cache
# The file system that hosts the FlexCache volume. This module creates NO
# volumes: the FlexCache volume is created by stacks/04-flexcache through the
# ONTAP API, pointing at a volume on the FSx for ONTAP Origin (modules/03-fsxn-origin).
#
# TODO (layer 2) - resources this module will still create:
#
#   random_password.fsxadmin
#   aws_secretsmanager_secret(+_version).fsxadmin   JSON {"username":"fsxadmin","password":"..."}
#   aws_fsx_ontap_file_system.this                  subnet_ids: first 1 (Single-AZ) or 2 (Multi-AZ),
#                                                   security_group_ids = [aws_security_group.fsxn.id]
#   aws_fsx_ontap_storage_virtual_machine.this      var.svm_name
#
# Outputs (see outputs.tf) expose the management + intercluster IPs that
# stacks/04-flexcache needs for the ONTAP provider and cluster peering.

# --- Security group ----------------------------------------------------------
# NFS (v3 + v4.x) plus what FlexCache and the ONTAP management API need.
# Kept identical to modules/03-fsxn-origin so both sides accept the same traffic.
# Port list follows the AWS "File system access control with Amazon VPC" guide for FSx for ONTAP.

locals {
  sg_ingress_rules = {
    # NFS
    "nfs-portmapper-tcp" = { protocol = "tcp", from = 111, to = 111, description = "NFS portmapper (rpcbind)" }
    "nfs-portmapper-udp" = { protocol = "udp", from = 111, to = 111, description = "NFS portmapper (rpcbind)" }
    "nfs-mountd-tcp"     = { protocol = "tcp", from = 635, to = 635, description = "NFS mountd" }
    "nfs-mountd-udp"     = { protocol = "udp", from = 635, to = 635, description = "NFS mountd" }
    "nfs-tcp"            = { protocol = "tcp", from = 2049, to = 2049, description = "NFS server daemon" }
    "nfs-udp"            = { protocol = "udp", from = 2049, to = 2049, description = "NFS server daemon" }
    "nfs-nlm-nsm-tcp"    = { protocol = "tcp", from = 4045, to = 4046, description = "NFS lock manager (NLM) + status monitor (NSM)" }
    "nfs-nlm-nsm-udp"    = { protocol = "udp", from = 4045, to = 4046, description = "NFS lock manager (NLM) + status monitor (NSM)" }
    "nfs-rquotad-udp"    = { protocol = "udp", from = 4049, to = 4049, description = "NFS quota protocol (rquotad)" }

    # Management - stacks/04-flexcache drives ONTAP over its REST API
    "mgmt-https" = { protocol = "tcp", from = 443, to = 443, description = "ONTAP REST API / System Manager" }
    "mgmt-ssh"   = { protocol = "tcp", from = 22, to = 22, description = "ONTAP CLI (SSH)" }

    # Intercluster - cluster/SVM peering and FlexCache data between origin and cache
    "intercluster" = { protocol = "tcp", from = 11104, to = 11105, description = "Intercluster: cluster peering + FlexCache" }

    # Diagnostics
    "icmp" = { protocol = "icmp", from = -1, to = -1, description = "ICMP (ping)" }
  }

  # One rule per (port rule, allowed CIDR) pair.
  sg_ingress = {
    for pair in setproduct(keys(local.sg_ingress_rules), var.allowed_cidrs) :
    "${pair[0]}_${pair[1]}" => merge(local.sg_ingress_rules[pair[0]], { cidr = pair[1] })
  }
}

resource "aws_security_group" "fsxn" {
  name        = "${var.name}-fsxn"
  description = "FSx for ONTAP Cache ${var.name}: NFS, ONTAP management and intercluster (FlexCache)"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-fsxn" })
}

resource "aws_vpc_security_group_ingress_rule" "fsxn" {
  for_each = local.sg_ingress

  security_group_id = aws_security_group.fsxn.id
  description       = each.value.description
  cidr_ipv4         = each.value.cidr
  ip_protocol       = each.value.protocol
  from_port         = each.value.from
  to_port           = each.value.to

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "fsxn_all" {
  security_group_id = aws_security_group.fsxn.id
  description       = "All outbound (NFS callbacks, intercluster, AWS endpoints)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = var.tags
}
