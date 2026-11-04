# modules/fsxn

One FSx for NetApp ONTAP file system + one SVM (+ optional volumes). Called by
`stacks/02-fsxn` once for the origin and, when `enable_cache_fsxn = true`, once for the cache.

Status: **interface defined, resources to be implemented** (see `main.tf`).

Design notes
- Same module for both sides; only inputs differ (origin gets `volumes`, cache gets none).
- fsxadmin password is generated and stored in Secrets Manager; `04-flexcache` reads it from there,
  so no passwords live in tfvars or Git.
- Defaults are tuned for clean performance numbers: `tiering_policy = NONE`, storage efficiency off,
  no snapshot policy.
- Single-AZ is the default because its management endpoint is reachable across VPC peering
  (Multi-AZ management uses floating IPs that need Transit Gateway). Default is Gen1 `SINGLE_AZ_1`
  at 128 MBps, the smallest/cheapest size.
- Security group (implemented) opens, from each of `allowed_cidrs`:
  NFS TCP+UDP 111, 635, 2049, 4045-4046 and UDP 4049; TCP 443 + 22 (ONTAP management);
  TCP 11104-11105 (intercluster / FlexCache); ICMP. All egress allowed.

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_ids`, `allowed_cidrs`, `svm_name` | required |
| `deployment_type` | `SINGLE_AZ_1` |
| `storage_capacity_gib` | `1024` |
| `throughput_capacity_per_ha_pair` | `128` |
| `ha_pairs` | `1` |
| `volumes` | `{}` |
