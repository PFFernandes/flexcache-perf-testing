# Layer 5 - Test bench: copies the bench (bench/ and profiles/) to the Linux EC2
# clients of stacks/03-ec2 and checks it works there. Optional: stacks 01-04 are a
# complete lab without it.
#
# Needs: the clients with SSM (03-ec2) on protocol = "nfs". FlexCache (04) is not
# required to deploy, but the cache client's /mnt/fsxn/vol_cache only mounts once it exists.
#
# Teardown: destroy this stack BEFORE 03-ec2 (it removes /opt/bench from the clients).

data "terraform_remote_state" "ec2" {
  backend = "local"
  config = {
    path = "${path.root}/../03-ec2/terraform.tfstate"
  }
}

locals {
  available = {
    origin = try(data.terraform_remote_state.ec2.outputs.origin_client, null)
    cache  = try(data.terraform_remote_state.ec2.outputs.cache_client, null)
  }

  clients = {
    for side in var.bench_clients : side => {
      region      = local.available[side].region
      instance_id = local.available[side].instance_id
    }
    if local.available[side] != null
  }

  not_linux = [for side, c in local.available : side if c != null && try(c.os, "linux") != "linux"]
  no_ssm    = [for side in keys(local.clients) : side if !try(local.available[side].ssm_enabled, false)]
}

resource "terraform_data" "prerequisites" {
  lifecycle {
    precondition {
      condition     = var.protocol == "nfs"
      error_message = "The test bench runs on the Linux NFS clients. With protocol = \"smb\" the clients are Windows; set protocol = \"nfs\" to use the bench."
    }
    precondition {
      condition     = length(local.not_linux) == 0
      error_message = "These clients in the 03-ec2 state are not Linux: ${join(", ", local.not_linux)}. Re-apply 03-ec2 with protocol = \"nfs\"."
    }
    precondition {
      condition     = length(local.clients) > 0
      error_message = "None of bench_clients (${join(", ", var.bench_clients)}) is in the 03-ec2 state. Apply 03-ec2 first."
    }
    precondition {
      condition     = length(local.no_ssm) == 0
      error_message = "These clients have no SSM (enable_ssm = true in stacks/03-ec2), which the bench is sent through: ${join(", ", local.no_ssm)}."
    }
  }
}

module "bench" {
  count  = var.protocol == "nfs" && length(local.not_linux) == 0 && length(local.no_ssm) == 0 && length(local.clients) > 0 ? 1 : 0
  source = "../../modules/09-bench-deploy"

  clients          = local.clients
  source_root      = abspath("${path.root}/../..")
  install_packages = var.install_packages
  run_tests        = var.run_tests

  depends_on = [terraform_data.prerequisites]
}
