# modules/04-fsxn-origin — FSx for ONTAP Origin

The FSx for ONTAP Origin: one file system + one SVM + the origin FlexVol volume(s) that hold the
test data set. The FlexCache on the FSx for ONTAP Cache (`modules/05-fsxn-cache`) points at these
volumes. Called by `stacks/02-fsxn` (always deployed).

Status: **security group implemented; file system, SVM and volumes to be implemented**
(see `main.tf`).

Design notes
- The fsxadmin password is **the same on both FSx for ONTAP**. `stacks/02-fsxn` generates it once,
  stores it in one Secrets Manager secret (`<creator>-<project>/fsxadmin`, origin region) and passes it in as
  `fsxadmin_password`; `04-flexcache` reads that secret. No passwords live in tfvars or Git.
- Defaults are tuned for clean performance numbers: `tiering_policy = NONE`, storage efficiency off,
  no snapshot policy.
- Single-AZ is the default because its management endpoint is reachable across VPC peering
  (Multi-AZ management uses floating IPs that need Transit Gateway). Default is Gen1 `SINGLE_AZ_1`
  at 128 MBps, the smallest/cheapest size.
- Security group (implemented, identical to `05-fsxn-cache`) opens, from each of `allowed_cidrs`:
  NFS TCP+UDP 111, 635, 2049, 4045-4046 and UDP 4049; TCP 443 + 22 (ONTAP management);
  TCP 11104-11105 (intercluster / FlexCache); ICMP. All egress allowed.

**Tags:** every resource (security group and each of its rules today; file system, SVM, volumes
once implemented) gets the `Creator` tag (provider default_tags, `creator` in `common.tfvars`) and a `Name` that starts with `<creator>-<project>` (`pedro-flexcache-perf-origin-fsxn-sg`, `...-fsxn` for the file system).

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_ids`, `allowed_cidrs`, `fsxadmin_password` | required |
| `svm_name` | `svm_origin` |
| `deployment_type` | `SINGLE_AZ_1` |
| `storage_capacity_gib` | `1024` |
| `throughput_capacity_per_ha_pair` | `128` |
| `ha_pairs` | `1` |
| `volumes` | `{}` |
