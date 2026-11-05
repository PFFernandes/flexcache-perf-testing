# modules/07-ontap-flexcache

ONTAP-level configuration, done through the **NetApp/netapp-ontap** Terraform provider (ONTAP REST API),
because the AWS API has no cluster peering or FlexCache operations:

1. Cluster peer (cache ⇄ origin) over the intercluster endpoints
2. SVM peer with the `flexcache` application
3. FlexCache volume on the cache SVM, pointing at the origin volume

Status: **interface defined, resources to be implemented** (see `main.tf`).

The provider talks HTTPS to both FSxN **management** endpoints, which are private IPs. From your
Mac it goes through `scripts/ontap-tunnel.sh`: an SSH tunnel through the EC2 Instance Connect
Endpoint to the helper EC2 (`stacks/03-helper`), forwarding `localhost:8443` (origin) and
`localhost:9443` (cache). The helper is only the path for these API calls; peering and FlexCache
traffic flow cluster to cluster over the intercluster LIFs.

**Tags:** these are ONTAP objects, not AWS resources, so AWS tags don't apply. The FlexCache
volume will carry an ONTAP comment with the Creator instead.

| Input | Default |
|---|---|
| `origin_intercluster_ips`, `cache_intercluster_ips` | required |
| `origin_svm_name`, `cache_svm_name`, `origin_volume_name` | required |
| `flexcache_name` | `vol_cache` |
| `flexcache_size_gib` | `500` |
| `flexcache_junction_path` | `/vol_cache` |
| `aggregates` | `["aggr1"]` |
