# TODO (layer 3) - resources this module will create:
#
#   data.aws_ssm_parameter.al2023        (when var.ami_id == null)
#   aws_iam_role + instance profile      AmazonSSMManagedInstanceCore + var.additional_policy_arns
#   aws_security_group.client            egress all; ingress SSH/ICMP from var.allowed_ingress_cidrs
#   aws_instance.this                    IMDSv2 required, gp3 root, user_data below
#
# Tagging: every resource gets tags = merge(local.tags, { Name = ... }), where
# local.tags = merge(var.tags, { Module = "06-ec2-client" }). aws_instance also
# sets volume_tags so the root EBS volume is tagged too.
#
# user_data (cloud-init) will:
#   - dnf install var.packages
#   - tune NFS client (sunrpc slot table) and create /mnt/fsxn
#
# NFS mounts are intentionally NOT done here: the test scripts in scripts/ mount
# with the options being tested (vers, nconnect, rsize/wsize), and on the cache
# side the FlexCache volume only exists after stack 04.
