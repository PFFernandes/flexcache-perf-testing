# modules/vpc-peering

Peers the origin VPC (requester) with the cache VPC (accepter) and adds routes on both sides.
Works same-region or cross-region. Needs two provider aliases:

```hcl
module "peering" {
  source    = "../../modules/vpc-peering"
  providers = { aws.requester = aws.origin, aws.accepter = aws.cache }
  # ...
}
```

**Why peering is enough for FlexCache:** cluster peering and FlexCache traffic use the FSxN
*intercluster* endpoints, which have IPs inside the VPC subnets, so they route over peering.
Caveat for Multi-AZ: the *management* and NFS/SMB endpoints of a Multi-AZ file system use
floating IPs outside the VPC CIDR, which do **not** route over peering (Transit Gateway needed).
Single-AZ file systems don't have this limitation.

**Outputs:** `peering_connection_id`, `cross_region`.
