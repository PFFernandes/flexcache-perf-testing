# FlexCache performance testing on FSx for NetApp ONTAP

Terraform automation to build an origin/cache FSx for ONTAP (FSxN) environment and measure
FlexCache read performance. Everything is split into **layers you deploy one at a time**, the
cache side is **optional** at every layer, and everything runs from **your Mac**: Terraform state
stays on it, and the private FSxN management endpoints are reached through SSM tunnels, so no bastion
host and no open inbound ports are needed.

```
   YOUR MAC: git, terraform, aws cli + Session Manager plugin, local state
        │  AWS APIs (stacks 01-03)          SSM tunnel localhost:8443 / :9443 (stack 04)
        ▼                                        ▼
             ORIGIN VPC (10.10.0.0/16)                  CACHE VPC (10.20.0.0/16)
  ┌───────────────────────────────────────┐   VPC peering   ┌───────────────────────────────────────┐
  │  FSxN origin  (svm_origin/vol_origin) │◄──intercluster─►│  FSxN cache  (svm_cache/vol_cache)    │  optional
  │                                       │   TCP 11104/5   │      FlexCache of vol_origin          │
  │  EC2 origin client                    │                 │  EC2 cache client                     │  optional
  │   - writes the test dataset           │                 │   - mounts vol_cache, runs read tests │
  │   - SSM tunnel host for both FSxN mgmt│                 │                                       │
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
│   ├── 01-landing-zone/        Network Origin + Network Cache + peering                  ✅
│   ├── 02-fsxn/                FSx for ONTAP Origin [+ Cache] + shared fsxadmin secret   wired
│   ├── 03-ec2/                 origin client [+ cache client if enable_cache_ec2]        wired
│   └── 04-flexcache/           ONTAP: peering + FlexCache volume                         wired
├── scripts/
│   ├── ontap-tunnel.sh         SSM tunnels Mac -> both FSxN mgmt endpoints (for stack 04)
│   ├── origin/                 dataset generation
│   └── cache/                  read benchmark
├── common.tfvars.example       project, creator, regions, AZs
└── tf.sh                       wrapper: ./tf.sh <stack> <command>
```

**Modules vs stacks:** a *module* is a building block ("how to build one FSxN"). A *stack* is a
deployable unit with its own state that calls modules ("build the origin FSxN, and the cache one if
enabled"). Stacks read each other's outputs from the local state files:

```
01-landing-zone ──► 02-fsxn ──┬──► 04-flexcache
        └─────────► 03-ec2 ──┘   (origin client = SSM tunnel host)
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
| 04 | `04-flexcache` | `02-fsxn` (both FSx for ONTAP, mgmt + intercluster IPs, shared fsxadmin secret) · `03-ec2` (origin client = SSM tunnel host) | `07-ontap-flexcache` |

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

## Tagging and names

Every AWS resource gets two tags:

| Tag | Set by | Example |
|---|---|---|
| `Creator` | provider `default_tags` in every stack | `pedro` (`creator` in `common.tfvars`) |
| `Name` | each module | `pedro-flexcache-perf-origin-vpc` |

Every name is `<creator>-<project>-<side>-<object>`, so you can tell at a glance who created it and
what it is:

| Object | Name |
|---|---|
| VPC / subnets | `pedro-flexcache-perf-origin-vpc`, `pedro-flexcache-perf-origin-private-eu-west-1a` |
| route tables, IGW, NAT | `...-origin-private-rt`, `...-origin-igw`, `...-origin-nat`, `...-origin-nat-eip` |
| peering | `pedro-flexcache-perf-origin-to-cache` |
| FSx for ONTAP | `pedro-flexcache-perf-origin-fsxn`, its security group `...-origin-fsxn-sg` |
| fsxadmin secret | `pedro-flexcache-perf/fsxadmin` |
| EC2 clients | `pedro-flexcache-perf-origin-client`, `pedro-flexcache-perf-cache-client` |

The prefix is `<creator>-<project>` from `common.tfvars`, so `creator` may only contain lowercase
letters, digits and hyphens.

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

## Your Mac

Everything runs from your Mac; there is no bastion host.

- **Tools:** `brew install hashicorp/tap/terraform awscli jq` and
  `brew install --cask session-manager-plugin` (Terraform ≥ 1.10, AWS CLI v2).
- **AWS credentials:** a profile that can create VPCs, peering, FSx, EC2, IAM roles and Secrets
  Manager secrets (`export AWS_PROFILE=<profile>`; in a sandbox account `AdministratorAccess` is
  simplest – `PowerUserAccess` is not enough, stack 03 creates IAM roles for the clients).
- **Reaching private IPs:** the FSxN management endpoints and the EC2 clients have private IPs only.
  `scripts/ontap-tunnel.sh` opens SSM port forwards through the origin EC2 client to both management
  IPs (the cache one over the origin ⇄ cache peering), and you log in to the clients with
  `aws ssm start-session --target <instance-id>`. The clients reach SSM through a NAT gateway, which is **off by
  default**: set `origin_nat_gateway = true` (and `cache_nat_gateway = true` for a cache client) in
  `stacks/01-landing-zone/terraform.tfvars` before you deploy EC2. FSx for ONTAP alone needs no NAT.

## Deploy (on your Mac)

```bash
git clone https://github.com/PFFernandes/flexcache-perf-testing.git && cd flexcache-perf-testing
cp common.tfvars.example common.tfvars                                   # regions, AZs, project, creator
export AWS_PROFILE=<your-profile>

# 1. landing zone
./tf.sh 01-landing-zone init && ./tf.sh 01-landing-zone apply

# 2. FSxN – origin first
./tf.sh 02-fsxn init && ./tf.sh 02-fsxn apply
#    ...later, add the cache
./tf.sh 02-fsxn apply -var enable_cache_fsxn=true      # or set it in stacks/02-fsxn/terraform.tfvars

# 3. EC2 clients (can run in parallel with step 2)
./tf.sh 03-ec2 init && ./tf.sh 03-ec2 apply
./tf.sh 03-ec2 apply -var enable_cache_ec2=true

# 4. FlexCache (needs both FSxN and the origin client)
./scripts/ontap-tunnel.sh                              # terminal 1: keep it running
./tf.sh 04-flexcache init && ./tf.sh 04-flexcache apply   # terminal 2
```

> Tip: once you use a toggle, put it in the stack's `terraform.tfvars` so a later plain `apply`
> doesn't switch it back off.

## State lives on your Mac

Each stack writes `stacks/<stack>/terraform.tfstate` in your clone (git-ignored – it contains the
generated fsxadmin password, so never commit it). Both FSx for ONTAP use the **same** fsxadmin
password: `02-fsxn` generates it once and stores it in the Secrets Manager secret
`<creator>-<project>/fsxadmin` in the origin region. To read it:
`aws secretsmanager get-secret-value --secret-id <creator>-<project>/fsxadmin --region <origin_region>`.

- **Don't delete the clone before you destroy the lab**, and keep a backup of the `*.tfstate` files
  (e.g. Time Machine). Without them Terraform no longer knows what it created and you'd have to
  clean up by hand.
- Moving to S3 later is a one-file change per stack (`backend.tf`) plus `terraform init -migrate-state`.

## Destroy (reverse order)

```bash
./tf.sh 04-flexcache destroy     # needs scripts/ontap-tunnel.sh running; removes FlexCache + peering first
./tf.sh 03-ec2 destroy
./tf.sh 02-fsxn destroy
./tf.sh 01-landing-zone destroy
```

## Network notes

- **Availability Zones** are set in `common.tfvars` as letters added to the region:
  `origin_azs = ["a"]` and `cache_azs = ["a"]` (default `<region>a`, e.g. `eu-west-1a`). Each AZ gets
  one private /24 (`x.x.1.0`, `x.x.2.0`, ...), and the first AZ also gets one public /24 (`x.x.101.0`)
  when NAT is on. Single-AZ FSx for ONTAP and the EC2 clients use the first AZ. Multi-AZ FSx for ONTAP
  needs two, e.g. `["a", "b"]`; `02-fsxn` stops with an error otherwise.
- VPC CIDRs must not overlap (defaults: origin `10.10.0.0/16`, cache `10.20.0.0/16`).
- FlexCache and cluster peering use the FSxN **intercluster** endpoints (IPs inside the VPC), which
  route over the origin ⇄ cache peering.
- **Single-AZ** FSxN is the default: its management endpoint is an IP inside the VPC, so the SSM
  tunnel through the origin client reaches it (the cache one over the peering). Multi-AZ
  management/NFS endpoints use floating IPs that don't route over peering (would need Transit Gateway).

## Cost reminders

FSxN is billed per hour for throughput capacity + SSD. Destroy `02-fsxn` (and NAT gateways in
`01-landing-zone`) between test campaigns.
