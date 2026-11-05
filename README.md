# FlexCache performance testing on FSx for NetApp ONTAP

Terraform automation to build an origin/cache FSx for ONTAP (FSxN) environment and measure
FlexCache read performance. Everything is split into **layers you deploy one at a time**, the
cache side is **optional** at every layer, and everything runs from **one bastion host** that you
create manually.

```
                    BASTION VPC (created by you, e.g. default VPC 172.31.0.0/16)
                    ┌───────────────────────────────────────────┐
                    │  Bastion host: git, terraform, aws cli    │
                    │  runs every stack, holds the local state  │
                    └──────────┬─────────────────────┬──────────┘
                     peering   │                     │  peering
             ORIGIN VPC (10.10.0.0/16)               ▼  CACHE VPC (10.20.0.0/16)
  ┌───────────────────────────────────────┐   VPC peering   ┌───────────────────────────────────────┐
  │  FSxN origin  (svm_origin/vol_origin) │◄──intercluster─►│  FSxN cache  (svm_cache/vol_cache)    │  optional
  │                                       │   TCP 11104/5   │      FlexCache of vol_origin          │
  │  EC2 origin client                    │                 │  EC2 cache client                     │  optional
  │   - writes the test dataset           │                 │   - mounts vol_cache, runs read tests │
  └───────────────────────────────────────┘                 └───────────────────────────────────────┘
       origin_region                                              cache_region (same or different)
```

## Repository layout

```
.
├── modules/                    reusable building blocks (no backend, no provider config)
│   ├── 01-network-origin/      Network Origin: origin VPC, subnets, NAT (opt), S3        ✅ implemented
│   ├── 02-network-cache/       Network Cache: cache VPC, subnets, NAT (opt), S3          ✅ implemented
│   ├── 03-vpc-peering/         peering + routes, same- or cross-region                   ✅ implemented
│   ├── 04-fsxn-origin/         FSx for ONTAP Origin: FS + SVM + origin vol + SG          🔲 SG only
│   ├── 05-fsxn-cache/          FSx for ONTAP Cache: FS + SVM + SG (no volumes)           🔲 SG only
│   ├── 06-ec2-client/          AL2023 test client, SSM access, fio/nfs-utils             🔲 interface only
│   └── 07-ontap-flexcache/     cluster peer + SVM peer + FlexCache (ONTAP provider)      🔲 interface only
├── stacks/                     what you actually deploy – one local state file per stack
│   ├── 01-landing-zone/        Network Origin + Network Cache + peering [+ bastion]      ✅
│   ├── 02-fsxn/                FSx for ONTAP Origin [+ Cache] + shared fsxadmin secret   wired
│   ├── 03-ec2/                 origin client [+ cache client if enable_cache_ec2]        wired
│   └── 04-flexcache/           ONTAP: peering + FlexCache volume                         wired
├── scripts/
│   ├── origin/                 dataset generation
│   └── cache/                  read benchmark
├── common.tfvars.example       project, creator, regions
└── tf.sh                       wrapper: ./tf.sh <stack> <command>
```

**Modules vs stacks:** a *module* is a building block ("how to build one FSxN"). A *stack* is a
deployable unit with its own state that calls modules ("build the origin FSxN, and the cache one if
enabled"). Stacks read each other's outputs from the local state files:

```
01-landing-zone ──► 02-fsxn ──► 04-flexcache
        └─────────► 03-ec2
```

## Creation order

Stacks and modules are both numbered in the order they are created. A number only ever depends on
lower numbers, so deploy top-down and destroy bottom-up.

**Stacks** (each has its own state; deploy `01` → `04`, destroy `04` → `01`):

| # | Stack | Depends on | Calls modules |
|---|---|---|---|
| 01 | `01-landing-zone` | – | `01-network-origin`, `02-network-cache`, `03-vpc-peering` |
| 02 | `02-fsxn` | `01-landing-zone` (VPC, subnets, CIDRs) | `04-fsxn-origin`, `05-fsxn-cache` |
| 03 | `03-ec2` | `01-landing-zone` (subnets); can run in parallel with `02-fsxn` | `06-ec2-client` |
| 04 | `04-flexcache` | `02-fsxn` (both FSx for ONTAP, mgmt + intercluster IPs, shared fsxadmin secret) | `07-ontap-flexcache` |

**Modules** (building blocks, in creation order):

| # | Module | Side | Needs (from lower numbers) | Used by stack |
|---|---|---|---|---|
| 01 | `01-network-origin` | Origin | – | `01-landing-zone` |
| 02 | `02-network-cache` | Cache | – (independent of 01, but must not overlap its CIDR) | `01-landing-zone` |
| 03 | `03-vpc-peering` | both | `01` + `02`: VPC IDs, route tables, CIDRs | `01-landing-zone` |
| 04 | `04-fsxn-origin` | Origin | `01`: VPC, private subnets · `03`: reachability for intercluster + mgmt | `02-fsxn` |
| 05 | `05-fsxn-cache` | Cache | `02`: VPC, private subnets · `03` · created after the Origin it caches (`04`) | `02-fsxn` |
| 06 | `06-ec2-client` | both | `01` (origin client) / `02` (cache client): subnet · NFS mounts target `04`/`05` at run time | `03-ec2` |
| 07 | `07-ontap-flexcache` | both | `04` + `05`: mgmt/intercluster IPs, origin volume | `04-flexcache` |

```
01-network-origin ──┐                  ┌──► 04-fsxn-origin ──┐
                    ├──► 03-vpc-peering┤                     ├──► 07-ontap-flexcache
02-network-cache  ──┘                  └──► 05-fsxn-cache  ──┘
01 / 02 ───────────────────────────────────► 06-ec2-client
```

## Tagging

Every AWS resource gets exactly **one** tag, `Creator`, and nothing else (no `Name`, so the AWS
console shows resource IDs). Its value is `creator` in `common.tfvars`. It is set once, through each
provider's `default_tags` in every stack; modules set no tags of their own.

Also tagged: the VPC's default security group, main route table and default network ACL, which AWS
creates untagged (the network modules adopt them), and the EC2 clients' root EBS volumes
(`volume_tags`, which `default_tags` don't reach).

Not taggable: routes and route-table associations (AWS has no tags for them), and ONTAP objects
in `07-ontap-flexcache` (cluster peer, SVM peer, FlexCache). The FlexCache volume gets an ONTAP
comment with the Creator instead.

## Why separate stacks

- **Deploy in steps.** Landing zone today, origin FSxN tomorrow, cache only if needed.
- **Small blast radius.** Rebuilding an EC2 client or the FlexCache can never touch the FSxN or VPCs.
- **ONTAP provider needs real endpoints.** The netapp-ontap provider is configured with the FSxN
  management IPs, which must be known at plan time – so ONTAP config has to be a later stack.
- **Faster iterations.** FSxN takes a long time to create; EC2/benchmark changes don't wait for it.

## Optional cache side

| What | Where | Default |
|---|---|---|
| Cache VPC + peering | `01-landing-zone` | always created (free, except NAT) |
| FSx for ONTAP Cache | `02-fsxn` → `enable_cache_fsxn` | `false` |
| Cache EC2 client | `03-ec2` → `enable_cache_ec2` | `false` |
| FlexCache volume | `04-flexcache` | only run it once the cache FSxN exists |

Turning a toggle on and re-applying **adds** the cache resources without changing the origin ones.
Turning it off removes only the cache resources.

## The bastion host

You create it by hand (it is deliberately **not** managed by this repo, so destroying the lab never
destroys the machine that holds the state).

- **OS / tools:** any Linux, e.g. Amazon Linux 2023, with `git`, `terraform` ≥ 1.10 and `aws` CLI v2.
- **Permissions:** an instance profile (IAM role) that can create VPCs, peering, FSx, EC2, IAM roles
  and Secrets Manager secrets. In a sandbox account the simplest is `AdministratorAccess`
  (`PowerUserAccess` is not enough – stack 03 creates IAM roles for the clients).
- **Network:** its VPC CIDR must not overlap `10.10.0.0/16` / `10.20.0.0/16` (the default VPC,
  `172.31.0.0/16`, is fine). Put its VPC ID in `stacks/01-landing-zone/terraform.tfvars` as
  `bastion_vpc_id`; stack 01 then peers it with both test VPCs and adds the routes. That is what lets
  stack 04 reach both FSxN management IPs, and lets you SSH from the bastion to the clients.
- **Outbound internet** to download Terraform providers (registry.terraform.io, releases.hashicorp.com).

## Deploy (on the bastion)

```bash
git clone <this repo> && cd flexcache-perf-testing
cp common.tfvars.example common.tfvars                                   # regions, project, creator
cp stacks/01-landing-zone/terraform.tfvars.example stacks/01-landing-zone/terraform.tfvars   # set bastion_vpc_id

# 1. landing zone
./tf.sh 01-landing-zone init && ./tf.sh 01-landing-zone apply

# 2. FSxN – origin first
./tf.sh 02-fsxn init && ./tf.sh 02-fsxn apply
#    ...later, add the cache
./tf.sh 02-fsxn apply -var enable_cache_fsxn=true      # or set it in stacks/02-fsxn/terraform.tfvars

# 3. EC2 clients (can run in parallel with step 2)
./tf.sh 03-ec2 init && ./tf.sh 03-ec2 apply
./tf.sh 03-ec2 apply -var enable_cache_ec2=true

# 4. FlexCache (needs both FSxN)
./tf.sh 04-flexcache init && ./tf.sh 04-flexcache apply
```

> Tip: once you use a toggle, put it in the stack's `terraform.tfvars` so a later plain `apply`
> doesn't switch it back off.

## State lives on the bastion

Each stack writes `stacks/<stack>/terraform.tfstate` on the bastion (git-ignored – it contains the
generated fsxadmin password, so never commit it). Both FSx for ONTAP use the **same** fsxadmin
password: `02-fsxn` generates it once and stores it in the Secrets Manager secret
`<project>/fsxadmin` in the origin region. To read it on the bastion:
`aws secretsmanager get-secret-value --secret-id <project>/fsxadmin --region <origin_region>`.

- **Destroy the lab before you terminate the bastion**, or copy the `*.tfstate` files off first.
  Without them Terraform no longer knows what it created and you'd have to clean up by hand.
- Moving to S3 later is a one-file change per stack (`backend.tf`) plus `terraform init -migrate-state`.

## Destroy (reverse order)

```bash
./tf.sh 04-flexcache destroy     # remove FlexCache + peering relationships first
./tf.sh 03-ec2 destroy
./tf.sh 02-fsxn destroy
./tf.sh 01-landing-zone destroy  # also removes the bastion peering + the routes it added
```

## Network notes

- VPC CIDRs must not overlap (defaults: origin `10.10.0.0/16`, cache `10.20.0.0/16`).
- FlexCache and cluster peering use the FSxN **intercluster** endpoints (IPs inside the VPC), which
  route over the origin ⇄ cache peering.
- **Single-AZ** FSxN is the default: its management endpoint is also inside the VPC, so the bastion
  reaches it over the bastion peering. Multi-AZ management/NFS endpoints use floating IPs that don't
  route over peering (would need Transit Gateway).

## Cost reminders

FSxN is billed per hour for throughput capacity + SSD. Destroy `02-fsxn` (and NAT gateways in
`01-landing-zone`) between test campaigns.
