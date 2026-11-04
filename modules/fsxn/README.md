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
  (Multi-AZ management uses floating IPs that need Transit Gateway).

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_ids`, `allowed_cidrs`, `svm_name` | required |
| `deployment_type` | `SINGLE_AZ_2` |
| `storage_capacity_gib` | `1024` |
| `throughput_capacity_per_ha_pair` | `1536` |
| `ha_pairs` | `1` |
| `volumes` | `{}` |
