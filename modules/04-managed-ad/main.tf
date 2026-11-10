# AWS Managed Microsoft AD
# Only deployed when protocol = "smb" (stacks/01-landing-zone). Lives in the
# origin VPC, on two subnets in different AZs (AWS always runs two domain
# controllers). Both FSx for ONTAP SVMs join this domain in stacks/02-fsxn, and
# the Windows clients (stacks/03-ec2) map the SMB shares with its Admin account.
#
# The cache side reaches the domain controllers over the VPC peering, so the
# directory's own security group gets rules for the peer VPC CIDRs.
#
# Resources:
#   aws_directory_service_directory.this        MicrosoftAD, Standard edition by default
#   aws_vpc_security_group_ingress_rule.peer     AD ports from each CIDR in var.peer_cidrs
#
# Tags: Name = <var.name>-... here, plus the Creator tag from the provider default_tags.

resource "aws_directory_service_directory" "this" {
  type       = "MicrosoftAD"
  edition    = var.edition
  name       = var.domain_name
  short_name = var.short_name
  password   = var.admin_password

  description = "Managed AD for ${var.name} (SMB on FSx for ONTAP)"

  vpc_settings {
    vpc_id     = var.vpc_id
    subnet_ids = var.subnet_ids
  }

  tags = { Name = "${var.name}-ad" }
}

# --- Reach from the peer VPC ---------------------------------------------------
# AWS creates the directory's security group for its own VPC. These rules add the
# ports a domain member needs (DNS, Kerberos, LDAP, SMB, RPC) for the peer VPC.

locals {
  ad_ports = {
    "dns-tcp"      = { protocol = "tcp", from = 53, to = 53 }
    "dns-udp"      = { protocol = "udp", from = 53, to = 53 }
    "kerberos-tcp" = { protocol = "tcp", from = 88, to = 88 }
    "kerberos-udp" = { protocol = "udp", from = 88, to = 88 }
    "ntp-udp"      = { protocol = "udp", from = 123, to = 123 }
    "rpc-tcp"      = { protocol = "tcp", from = 135, to = 135 }
    "netbios-udp"  = { protocol = "udp", from = 137, to = 138 }
    "ldap-tcp"     = { protocol = "tcp", from = 389, to = 389 }
    "ldap-udp"     = { protocol = "udp", from = 389, to = 389 }
    "smb-tcp"      = { protocol = "tcp", from = 445, to = 445 }
    "kpasswd-tcp"  = { protocol = "tcp", from = 464, to = 464 }
    "kpasswd-udp"  = { protocol = "udp", from = 464, to = 464 }
    "ldaps-tcp"    = { protocol = "tcp", from = 636, to = 636 }
    "gc-tcp"       = { protocol = "tcp", from = 3268, to = 3269 }
    "adws-tcp"     = { protocol = "tcp", from = 9389, to = 9389 }
    "rpc-dyn-tcp"  = { protocol = "tcp", from = 49152, to = 65535 }
  }

  peer_rules = {
    for pair in setproduct(keys(local.ad_ports), var.peer_cidrs) :
    "${pair[0]}_${pair[1]}" => merge(local.ad_ports[pair[0]], { rule = pair[0], cidr = pair[1] })
  }
}

resource "aws_vpc_security_group_ingress_rule" "peer" {
  for_each = local.peer_rules

  security_group_id = aws_directory_service_directory.this.security_group_id
  description       = "AD ${each.value.rule} from the peer VPC"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = each.value.protocol
  from_port         = each.value.from
  to_port           = each.value.to

  tags = { Name = "${var.name}-ad-${each.value.rule}-${each.value.cidr}" }
}
