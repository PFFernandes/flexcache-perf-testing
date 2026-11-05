# modules/07-ontap-flexcache

ONTAP-level configuration, done through the **NetApp/netapp-ontap** Terraform provider (ONTAP REST API),
because the AWS API has no cluster peering or FlexCache operations:

1. Cluster peer (cache ⇄ origin) over the intercluster endpoints
2. SVM peer with the `flexcache` application
3. FlexCache volume on the cache SVM, pointing at the origin volume

Status: **interface defined, resources to be implemented** (see `main.tf`).

The provider talks HTTPS to both FSxN **management** endpoints, which are private IPs. So stack 04
must run from somewhere that can reach them: your bastion, whose VPC `01-landing-zone` peers with
both the origin and the cache VPC (`bastion_vpc_id`).

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
