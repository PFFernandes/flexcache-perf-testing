# modules/06-ontap-flexcache

ONTAP-level configuration, done through the **NetApp/netapp-ontap** Terraform provider (ONTAP REST API),
because the AWS API has no cluster peering or FlexCache operations:

1. Cluster peer (cache ⇄ origin) over the intercluster endpoints
2. SVM peer with the `flexcache` application
3. FlexCache volume on the cache SVM, pointing at the origin volume

Status: **interface defined, resources to be implemented** (see `main.tf`).

The provider talks HTTPS to both FSxN **management** endpoints, which are private IPs. Stack 03
connects to them directly, so the machine running it (your Mac) needs a network path into the VPCs,
e.g. AWS Client VPN. `origin_ontap_endpoint` / `cache_ontap_endpoint` in stack 03 can point it
elsewhere, e.g. at a local port forward.

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
