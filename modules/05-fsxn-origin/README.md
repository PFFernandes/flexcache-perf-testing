# modules/05-fsxn-origin — FSx for ONTAP Origin

The FSx for ONTAP Origin: one file system + one SVM + the origin volume(s) – a **FlexGroup** by default – that hold the
test data set. The FlexCache on the FSx for ONTAP Cache (`modules/06-fsxn-cache`) points at these
volumes. Called by `stacks/02-fsxn` when `deploy_origin = true` (common.tfvars).

Status: **implemented** – security group, file system (`<name>-fsxn`), SVM and origin volume(s).

Design notes
- The fsxadmin password is **the same on both FSx for ONTAP**. `stacks/02-fsxn` generates it once,
  stores it in one Secrets Manager secret (`<creator>-<project>/fsxadmin`, origin region) and passes it in as
  `fsxadmin_password`; `04-flexcache` reads that secret. No passwords live in tfvars or Git.
- Origin volume defaults: **FlexGroup** (`volume_style = FLEXGROUP`, AWS default of 8 constituents on
  `aggr1`, so at least 800 GiB), **storage efficiency on**, `tiering_policy = NONE` (data stays on
  SSD), no snapshot policy. FlexCache supports FlexGroup origins.
- Single-AZ is the default because its management endpoint is reachable across VPC peering
  (Multi-AZ management uses floating IPs that need Transit Gateway). Default is Gen1 `SINGLE_AZ_1`
  at 128 MBps, the smallest/cheapest size.
- Security group (implemented, identical to `06-fsxn-cache`) opens, from each of `allowed_cidrs`:
  NFS TCP+UDP 111, 635, 2049, 4045-4046 and UDP 4049; TCP 443 + 22 (ONTAP management);
  TCP 11104-11105 (intercluster / FlexCache); ICMP. All egress allowed.
- **SMB** (`protocol = "smb"`): the SVM joins `active_directory` (the AWS Managed AD from
  `stacks/01-landing-zone`, with its `Admin` account and the delegated OU and FSx admins group), which
  creates its SMB server under `netbios_name`; root volume security becomes NTFS and TCP 445 opens.

**Tags:** every resource (security group and its rules, file system, SVM, volumes) gets the `Creator` tag (provider default_tags, `creator` in `common.tfvars`) and a `Name` that starts with `<creator>-<project>` (`pedro-flexcache-perf-origin-fsxn-sg`, `...-fsxn` for the file system).

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_ids`, `allowed_cidrs`, `fsxadmin_password` | required |
| `svm_name` | `svm_origin` |
| `deployment_type` | `SINGLE_AZ_1` |
| `storage_capacity_gib` | `1024` |
| `throughput_capacity_per_ha_pair` | `128` |
| `ha_pairs` | `1` |
| `volumes` | `{}` (stack 02 passes `vol_origin`: FlexGroup, 800 GiB, `/vol_origin`, storage efficiency on) |
| `automatic_backup_retention_days` | `0` (no backups) |

| `protocol` | `nfs` (`smb`: NTFS, port 445, domain join) |
| `active_directory`, `ad_password` | `null` (required for SMB) |

**Outputs:** `security_group_id`, `file_system_id`, `management_ip`, `intercluster_ips`, `svm_id`,
`svm_name`, `svm_nfs_ip`, `svm_smb_dns_name`, `svm_smb_ip`, `volumes`.
