# modules/06-ec2-client

Linux test client (Amazon Linux 2023). Called by `stacks/03-ec2` once for the origin and,
when `enable_cache_ec2 = true`, once for the cache.

Status: **interface defined, resources to be implemented** (see `main.tf`).

Roles
- **Origin client** – generates the dataset on the origin volume (`scripts/origin/`).
- **Cache client** – mounts the FlexCache volume and runs the read benchmark (`scripts/cache/`).

Terraform itself runs on your Mac, not on these clients. You reach them with SSM Session Manager
(`aws ssm start-session`), so they need no public IP and no inbound rule from the internet. The
origin client is also the SSM tunnel host that lets stack 04 reach both FSx for ONTAP management
endpoints (`scripts/ontap-tunnel.sh`).

**Tags:** every resource gets only the `Creator` tag, from the provider default_tags (`creator` in `common.tfvars`).
The instance copies it onto its root EBS volume (`volume_tags`), which default_tags don't reach.

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_id` | required |
| `instance_type` | `c6in.2xlarge` |
| `ami_id` | latest AL2023 |
| `packages` | nfs-utils, fio, git, jq, python3, sysstat, iperf3 |
| `additional_policy_arns` | `[]` |
