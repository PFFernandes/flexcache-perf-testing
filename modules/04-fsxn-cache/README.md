# modules/04-fsxn-cache — FSx for ONTAP Cache

The FSx for ONTAP Cache: one file system + one SVM that will host the FlexCache volume. It creates
**no volumes**: `stacks/04-flexcache` creates the FlexCache volume through the ONTAP API, pointing
at the origin volume on the FSx for ONTAP Origin (`modules/03-fsxn-origin`). Called by
`stacks/02-fsxn` only when `enable_cache_fsxn = true`.

Status: **security group implemented; file system, SVM and secret to be implemented**
(see `main.tf`).

Design notes
- fsxadmin password is generated and stored in Secrets Manager; `04-flexcache` reads it from there,
  so no passwords live in tfvars or Git.
- Single-AZ is the default because its management endpoint is reachable across VPC peering
  (Multi-AZ management uses floating IPs that need Transit Gateway). Default is Gen1 `SINGLE_AZ_1`
  at 128 MBps, the smallest/cheapest size.
- Security group (implemented, identical to `03-fsxn-origin`) opens, from each of `allowed_cidrs`:
  NFS TCP+UDP 111, 635, 2049, 4045-4046 and UDP 4049; TCP 443 + 22 (ONTAP management);
  TCP 11104-11105 (intercluster / FlexCache); ICMP. All egress allowed.

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_ids`, `allowed_cidrs` | required |
| `svm_name` | `svm_cache` |
| `deployment_type` | `SINGLE_AZ_1` |
| `storage_capacity_gib` | `1024` |
| `throughput_capacity_per_ha_pair` | `128` |
| `ha_pairs` | `1` |
