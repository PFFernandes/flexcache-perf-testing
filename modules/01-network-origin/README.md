# modules/01-network-origin — Network Origin

The origin VPC: it hosts the FSx for ONTAP Origin (`modules/04-fsxn-origin`). Called once by `stacks/01-landing-zone` (`module "origin_network"`).
Its counterpart on the cache side is `modules/02-network-cache`; `modules/03-vpc-peering` connects the two.

**Creates:** VPC, private subnets (FSx for ONTAP), optional public subnet + IGW + single NAT gateway,
one private route table, a free S3 gateway endpoint, and adopts the VPC's default security group
(locked down: no rules), main route table and default network ACL (allow-all, as AWS creates it)
so that they are tagged too.

**Tags:** every resource gets the `Creator` tag (provider default_tags, `creator` in `common.tfvars`) and a `Name` that starts with `<creator>-<project>` (pedro-flexcache-perf-origin-vpc, -private-eu-west-1a, -nat, ...).
Routes and route-table associations can't be tagged in AWS.

| Input | Default | Notes |
|---|---|---|
| `cidr_block` | – | Must not overlap the cache VPC |
| `name` | – | Name prefix, e.g. `pedro-flexcache-perf-origin` |
| `azs` | `[]` (first available) | Full AZ names, e.g. `["eu-west-1a"]`. Stack 01 passes `<region>` + the letters in `common.tfvars` |
| `private_subnet_cidrs` | – | Exactly one per AZ in `azs`. Single-AZ FSxN uses the first, Multi-AZ the first two |
| `public_subnet_cidrs` | `[]` | Only needed for NAT |
| `enable_nat_gateway` | `false` | ~USD 1/day per NAT; turn off if you use SSM VPC endpoints instead |
| `enable_s3_gateway_endpoint` | `true` | AL2023 `dnf` works through it even without NAT |

**Outputs:** `vpc_id`, `vpc_cidr`, `azs`, `private_subnet_ids`, `public_subnet_ids`,
`private_route_table_ids`, `public_route_table_ids`, `nat_public_ip`.
