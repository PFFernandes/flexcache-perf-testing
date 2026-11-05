# modules/01-network-origin — Network Origin

The origin VPC: it hosts the FSx for ONTAP Origin (`modules/04-fsxn-origin`) and the origin EC2 client
(`modules/06-ec2-client`). Called once by `stacks/01-landing-zone` (`module "origin_network"`).
Its counterpart on the cache side is `modules/02-network-cache`; `modules/03-vpc-peering` connects the two.

**Creates:** VPC, private subnets (FSxN + EC2), optional public subnet + IGW + single NAT gateway,
one private route table, a free S3 gateway endpoint, and adopts the VPC's default security group
(locked down: no rules), main route table and default network ACL (allow-all, as AWS creates it)
so that they get the Creator tag too.

**Tags:** every resource gets only the `Creator` tag, from the provider default_tags (`creator` in `common.tfvars`).
Routes and route-table associations can't be tagged in AWS.

| Input | Default | Notes |
|---|---|---|
| `cidr_block` | – | Must not overlap the cache VPC |
| `private_subnet_cidrs` | – | One per AZ. Single-AZ FSxN uses the first, Multi-AZ the first two |
| `public_subnet_cidrs` | `[]` | Only needed for NAT |
| `enable_nat_gateway` | `true` | ~USD 1/day per NAT; turn off if you use SSM VPC endpoints instead |
| `enable_s3_gateway_endpoint` | `true` | AL2023 `dnf` works through it even without NAT |

**Outputs:** `vpc_id`, `vpc_cidr`, `azs`, `private_subnet_ids`, `public_subnet_ids`,
`private_route_table_ids`, `public_route_table_ids`, `nat_public_ip`.
