# Test bench delivery: copies the bench (bench/ and profiles/ from this repository) to
# the Linux EC2 clients, which have no internet and so can't clone the repository.
#
# Same pattern as modules/08-ontap-flexcache: Terraform runs files/deploy.sh on YOUR
# MAC, which packs the folders and sends them to each client with SSM Run Command.
# On the client, files/remote.sh unpacks them into /opt/bench, installs the
# `bench-dataset` command, prints checks (Python, PyYAML, mounts) and runs the tests.
#
# A change to any file in the bench folders (or to the settings) re-deploys on the next
# apply; nothing is sent when nothing changed. `terraform destroy` removes /opt/bench
# and the command from the clients; datasets on the volumes and ~/bench-results stay.
#
# Resources:
#   terraform_data.deploy["origin" | "cache"]   runs deploy.sh deploy / remove
#
# No AWS resources: only SSM Run Command calls, made by the AWS CLI on your Mac.

locals {
  # Every file that goes into the bundle, relative to source_root, without caches.
  files = sort(flatten([
    for dir in var.source_dirs : [
      for f in fileset("${var.source_root}/${dir}", "**") : "${dir}/${f}"
      if !strcontains(f, "__pycache__") && !endswith(f, ".pyc") && !endswith(f, ".DS_Store")
    ]
  ]))

  bundle_hash = sha256(join("\n", [for f in local.files : "${f} ${filesha256("${var.source_root}/${f}")}"]))
}

resource "terraform_data" "deploy" {
  for_each = var.clients

  # Re-deploy when the bench, the scripts or the settings change, or the client is new.
  triggers_replace = {
    bundle      = local.bundle_hash
    scripts     = sha256(join(",", [filesha256("${path.module}/files/deploy.sh"), filesha256("${path.module}/files/remote.sh")]))
    instance_id = each.value.instance_id
    packages    = join(",", var.install_packages)
    run_tests   = var.run_tests
  }

  # Destroy-time provisioners may only use self, so everything they need is stored here.
  input = {
    deploy_sh   = "${path.module}/files/deploy.sh"
    remote_sh   = "${path.module}/files/remote.sh"
    region      = each.value.region
    instance_id = each.value.instance_id
    side        = each.key
  }

  provisioner "local-exec" {
    command = "bash '${self.input.deploy_sh}'"
    environment = {
      ACTION      = "deploy"
      REGION      = self.input.region
      INSTANCE_ID = self.input.instance_id
      SIDE        = self.input.side
      REMOTE_SH   = self.input.remote_sh
      SOURCE_ROOT = var.source_root
      SOURCE_DIRS = join(" ", var.source_dirs)
      BUNDLE_HASH = local.bundle_hash
      PACKAGES    = join(",", var.install_packages)
      RUN_TESTS   = var.run_tests ? "1" : "0"
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${self.input.deploy_sh}'"
    environment = {
      ACTION      = "remove"
      REGION      = self.input.region
      INSTANCE_ID = self.input.instance_id
      SIDE        = self.input.side
      REMOTE_SH   = self.input.remote_sh
    }
  }
}
