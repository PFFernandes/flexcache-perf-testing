# Layer 3 - test clients, one per side:
#   protocol = "nfs" (default): Amazon Linux 2023, NFS mounts under /mnt/fsxn.
#   protocol = "smb":           Windows Server 2022 joined to the Managed AD (domain_join),
#                               SMB shares mapped to drive letters.
#   Origin client: origin VPC, same subnet as the FSx for ONTAP Origin.
#                  NFS: vol_origin -> /mnt/fsxn/vol_origin.  SMB: share origin -> O:
#   Cache client:  cache VPC, same subnet as the FSx for ONTAP Cache.
#                  NFS: vol_cache (FlexCache) -> /mnt/fsxn/vol_cache.  SMB: share cache -> X:
#                  cache_mounts_origin = true adds the Origin over the peering as a baseline.
# Each client is switched on with deploy_<side> (common.tfvars) AND <side>_ec2.
# Reads the networks from 01-landing-zone and the NFS endpoints from 02-fsxn.

data "terraform_remote_state" "lz" {
  backend = "local"
  config = {
    path = "${path.root}/../01-landing-zone/terraform.tfstate"
  }
}

data "terraform_remote_state" "fsxn" {
  backend = "local"
  config = {
    path = "${path.root}/../02-fsxn/terraform.tfstate"
  }
}

locals {
  lz          = data.terraform_remote_state.lz.outputs
  fsxn_origin = try(data.terraform_remote_state.fsxn.outputs.origin, null)
  fsxn_cache  = try(data.terraform_remote_state.fsxn.outputs.cache, null)

  want_origin = var.deploy_origin && var.origin_ec2
  want_cache  = var.deploy_cache && var.cache_ec2

  has_origin = try(local.lz.origin, null) != null && local.fsxn_origin != null
  has_cache  = try(local.lz.cache, null) != null && local.fsxn_cache != null

  smb       = var.protocol == "smb"
  os        = local.smb ? "windows" : "linux"
  directory = try(data.terraform_remote_state.lz.outputs.directory, null)
  ad_secret = local.smb && local.directory != null ? { name = local.directory.admin_secret.name } : null

  # Windows clients join the Managed AD (domain_join = true): domain DNS through the domain
  # controllers, Kerberos, domain logins over RDP.
  join = local.smb && var.domain_join && local.directory != null
  domain_join = local.join ? {
    domain_name = local.directory.domain_name
    dns_ips     = local.directory.dns_ips
    ou          = local.directory.computers_ou
  } : null

  # SMB shares, created by stacks/04-flexcache (share_names there, default origin / cache):
  # origin -> vol_origin, cache -> the FlexCache.
  # Joined: mapped by the SVM's SMB DNS name (in the AD domain), with its IP as a fallback.
  # Not joined: mapped by IP, since the VPC DNS doesn't resolve the AD domain.
  origin_shares = local.smb && try(local.fsxn_origin.svm_smb_ip, null) != null ? {
    origin = local.join && try(local.fsxn_origin.svm_smb_dns_name, null) != null ? {
      drive = var.smb_drives.origin, server = local.fsxn_origin.svm_smb_dns_name, fallback = local.fsxn_origin.svm_smb_ip
      } : {
      drive = var.smb_drives.origin, server = local.fsxn_origin.svm_smb_ip, fallback = null
    }
  } : {}
  cache_shares = merge(
    local.smb && try(local.fsxn_cache.svm_smb_ip, null) != null ? {
      cache = local.join && try(local.fsxn_cache.svm_smb_dns_name, null) != null ? {
        drive = var.smb_drives.cache, server = local.fsxn_cache.svm_smb_dns_name, fallback = local.fsxn_cache.svm_smb_ip
        } : {
        drive = var.smb_drives.cache, server = local.fsxn_cache.svm_smb_ip, fallback = null
      }
    } : {},
    var.cache_mounts_origin ? local.origin_shares : {},
  )

  mount_opts = var.nfs_options == null ? {} : { options = var.nfs_options }

  origin_mounts = local.fsxn_origin == null || local.smb ? {} : {
    vol_origin = merge({ server = local.fsxn_origin.svm_nfs_ip, export = local.fsxn_origin.junction_path }, local.mount_opts)
  }

  cache_mounts = merge(
    local.fsxn_cache == null || local.smb ? {} : {
      vol_cache = merge({ server = local.fsxn_cache.svm_nfs_ip, export = var.flexcache_junction_path }, local.mount_opts)
    },
    var.cache_mounts_origin ? local.origin_mounts : {},
  )
}

# Clear error when a client is wanted but its network or FSx for ONTAP isn't deployed.
resource "terraform_data" "prerequisites" {
  lifecycle {
    precondition {
      condition     = !local.want_origin || local.has_origin
      error_message = "Origin client wanted, but the Network Origin (01-landing-zone) or FSx for ONTAP Origin (02-fsxn) is missing. Apply those first, or set origin_ec2 = false."
    }
    precondition {
      condition     = !local.want_cache || local.has_cache
      error_message = "Cache client wanted, but the Network Cache (01-landing-zone) or FSx for ONTAP Cache (02-fsxn) is missing. Apply those first, or set cache_ec2 = false."
    }
    precondition {
      condition     = !local.smb || local.directory != null
      error_message = "protocol = \"smb\" but there is no Managed AD in the 01-landing-zone state. Apply 01-landing-zone and 02-fsxn with the same common.tfvars first."
    }
    precondition {
      condition     = !local.smb || (!local.want_origin || try(local.fsxn_origin.svm_smb_ip, null) != null) && (!local.want_cache || try(local.fsxn_cache.svm_smb_ip, null) != null)
      error_message = "protocol = \"smb\" but the SVMs in the 02-fsxn state have no SMB endpoint. Apply 02-fsxn with protocol = \"smb\" first."
    }
  }
}

# --- Origin client -------------------------------------------------------------
module "ec2_origin" {
  count = local.want_origin && local.has_origin ? 1 : 0

  source    = "../../modules/07-ec2-client"
  providers = { aws = aws.origin }

  name          = "${local.name_prefix}-origin-client"
  instance_name = "${var.creator}-origin-client"
  hostname      = "origin-client"
  vpc_id        = local.lz.origin.vpc_id
  subnet_id     = local.lz.origin.private_subnet_ids[0] # same subnet as the FSx for ONTAP Origin
  instance_type = var.instance_type
  architecture  = var.architecture
  enable_eice   = var.enable_eice
  enable_ssm    = var.enable_ssm
  nfs_mounts    = local.origin_mounts

  os                      = local.os
  smb_mappings            = local.origin_shares
  ad_secret               = local.ad_secret
  domain_join             = local.domain_join
  enable_secrets_endpoint = local.smb
}

# --- Cache client ----------------------------------------------------------------
module "ec2_cache" {
  count = local.want_cache && local.has_cache ? 1 : 0

  source    = "../../modules/07-ec2-client"
  providers = { aws = aws.cache }

  name          = "${local.name_prefix}-cache-client"
  instance_name = "${var.creator}-cache-client"
  hostname      = "cache-client"
  vpc_id        = local.lz.cache.vpc_id
  subnet_id     = local.lz.cache.private_subnet_ids[0] # same subnet as the FSx for ONTAP Cache
  instance_type = var.instance_type
  architecture  = var.architecture
  enable_eice   = var.enable_eice
  enable_ssm    = var.enable_ssm
  nfs_mounts    = local.cache_mounts

  os                      = local.os
  smb_mappings            = local.cache_shares
  ad_secret               = local.ad_secret
  domain_join             = local.domain_join
  enable_secrets_endpoint = local.smb
}
