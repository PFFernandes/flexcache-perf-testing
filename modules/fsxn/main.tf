# TODO (layer 2) - resources this module will create:
#
#   random_password.fsxadmin
#   aws_secretsmanager_secret(+_version).fsxadmin   JSON {"username":"fsxadmin","password":"..."}
#   aws_security_group.fsxn                          ingress from var.allowed_cidrs:
#        TCP 443 (mgmt/REST), 22 (ONTAP CLI), 111/635/2049/4045-4046 (NFS),
#        TCP 11104-11105 (intercluster: cluster peering + FlexCache), ICMP
#        UDP 111/635/2049/4045-4046
#   aws_fsx_ontap_file_system.this                  subnet_ids: first 1 (Single-AZ) or 2 (Multi-AZ)
#   aws_fsx_ontap_storage_virtual_machine.this      var.svm_name
#   aws_fsx_ontap_volume.this (for_each var.volumes)
#
# Outputs (see outputs.tf) expose the management + intercluster IPs that
# stacks/04-flexcache needs for the ONTAP provider and cluster peering.
