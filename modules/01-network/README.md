# modules/01-network

One VPC for one side of the test (called twice by `stacks/01-landing-zone`: origin and cache).

**Creates:** VPC, private subnets (FSxN + EC2), optional public subnet + IGW + single NAT gateway,
one private route table, and a free S3 gateway endpoint.

| Input | Default | Notes |
|---|---|---|
| `name` | – | Name prefix |
| `cidr_block` | – | Must not overlap the peer VPC |
| `private_subnet_cidrs` | – | One per AZ. Single-AZ FSxN uses the first, Multi-AZ the first two |
| `public_subnet_cidrs` | `[]` | Only needed for NAT |
| `enable_nat_gateway` | `true` | ~USD 1/day per NAT; turn off if you use SSM VPC endpoints instead |
| `enable_s3_gateway_endpoint` | `true` | AL2023 `dnf` works through it even without NAT |

**Outputs:** `vpc_id`, `vpc_cidr`, `azs`, `private_subnet_ids`, `public_subnet_ids`,
`private_route_table_ids`, `public_route_table_ids`, `nat_public_ip`.
