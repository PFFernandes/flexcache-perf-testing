# modules/02-network-cache — Network Cache

The cache VPC: it hosts the FSx for ONTAP Cache (`modules/05-fsxn-cache`) and the cache EC2 client
(`modules/06-ec2-client`). Called once by `stacks/01-landing-zone` (`module "cache_network"`).
Its counterpart on the origin side is `modules/01-network-origin`; `modules/03-vpc-peering` connects the two.

**Creates:** VPC, private subnets (FSxN + EC2), optional public subnet + IGW + single NAT gateway,
one private route table, a free S3 gateway endpoint, and adopts the VPC's default security group
(locked down: no rules), main route table and default network ACL (allow-all, as AWS creates it)
so that they are tagged too.

**Tags:** every resource gets the provider default tags (Project, Owner, Stack, Side, ManagedBy +
`extra_tags`) plus `Module = "02-network-cache"` and a `Name`. Routes and route-table associations can't be
tagged in AWS.

| Input | Default | Notes |
|---|---|---|
| `name` | – | Name prefix, e.g. `flexcache-perf-cache` |
| `cidr_block` | – | Must not overlap the origin VPC |
| `private_subnet_cidrs` | – | One per AZ. Single-AZ FSxN uses the first, Multi-AZ the first two |
| `public_subnet_cidrs` | `[]` | Only needed for NAT |
| `enable_nat_gateway` | `true` | ~USD 1/day per NAT; turn off if you use SSM VPC endpoints instead |
| `enable_s3_gateway_endpoint` | `true` | AL2023 `dnf` works through it even without NAT |
| `tags` | `{}` | Extra tags for this module only |

**Outputs:** `vpc_id`, `vpc_cidr`, `azs`, `private_subnet_ids`, `public_subnet_ids`,
`private_route_table_ids`, `public_route_table_ids`, `nat_public_ip`.
