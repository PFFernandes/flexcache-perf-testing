# modules/ec2-client

Linux test client (Amazon Linux 2023). Called by `stacks/03-ec2` once for the origin and,
when `enable_cache_ec2 = true`, once for the cache.

Status: **interface defined, resources to be implemented** (see `main.tf`).

Roles
- **Origin client** – generates the dataset on the origin volume (`scripts/origin/`).
- **Cache client** – mounts the FlexCache volume and runs the read benchmark (`scripts/cache/`).

Terraform itself runs on your bastion, not on these clients. Access from the bastion is SSH over the
bastion peering (set `key_name`), or SSM Session Manager.

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_id` | required |
| `instance_type` | `c6in.2xlarge` |
| `ami_id` | latest AL2023 |
| `packages` | nfs-utils, fio, git, jq, python3, sysstat, iperf3 |
| `additional_policy_arns` | `[]` |
