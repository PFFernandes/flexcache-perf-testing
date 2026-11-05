# modules/05-fsxn-cache — FSx for ONTAP Cache

The FSx for ONTAP Cache: one file system + one SVM that will host the FlexCache volume. It creates
**no volumes**: `stacks/03-flexcache` creates the FlexCache volume through the ONTAP API, pointing
at the origin volume on the FSx for ONTAP Origin (`modules/04-fsxn-origin`). Called by
`stacks/02-fsxn` only when `deploy_cache = true` (common.tfvars).

Status: **implemented** – security group, file system (`<name>-fsxn`) and SVM.

Design notes
- The fsxadmin password is **the same on both FSx for ONTAP**. `stacks/02-fsxn` generates it once,
  stores it in one Secrets Manager secret (`<creator>-<project>/fsxadmin`, origin region) and passes it in as
  `fsxadmin_password`; `03-flexcache` reads that secret. No passwords live in tfvars or Git.
- Single-AZ is the default because its management endpoint is reachable across VPC peering
  (Multi-AZ management uses floating IPs that need Transit Gateway). Default is Gen1 `SINGLE_AZ_1`
  at 128 MBps, the smallest/cheapest size.
- Security group (implemented, identical to `04-fsxn-origin`) opens, from each of `allowed_cidrs`:
  NFS TCP+UDP 111, 635, 2049, 4045-4046 and UDP 4049; TCP 443 + 22 (ONTAP management);
  TCP 11104-11105 (intercluster / FlexCache); ICMP. All egress allowed.

**Tags:** every resource (security group and its rules, file system, SVM) gets the `Creator` tag (provider default_tags, `creator` in `common.tfvars`) and a `Name` that starts with `<creator>-<project>` (`pedro-flexcache-perf-cache-fsxn-sg`, `...-fsxn` for the file system).

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_ids`, `allowed_cidrs`, `fsxadmin_password` | required |
| `svm_name` | `svm_cache` |
| `deployment_type` | `SINGLE_AZ_1` |
| `storage_capacity_gib` | `1024` |
| `throughput_capacity_per_ha_pair` | `128` |
| `ha_pairs` | `1` |
| `automatic_backup_retention_days` | `0` (no backups) |

**Outputs:** `security_group_id`, `file_system_id`, `management_ip`, `intercluster_ips`, `svm_id`,
`svm_name`, `svm_nfs_ip`.
