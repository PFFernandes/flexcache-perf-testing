# FlexCache performance testing on FSx for NetApp ONTAP

Terraform automation to build an origin/cache FSx for ONTAP (FSxN) environment and measure
FlexCache read performance. Everything is split into **layers you deploy one at a time**,
**Origin, Cache or both** can be deployed (two switches in `common.tfvars`), and everything runs
from **your Mac**, where the Terraform state stays. No bastion host: a small private **helper EC2**,
reached through an EC2 Instance Connect Endpoint, is the only path to the ONTAP management API.

```
   YOUR MAC: git, terraform, aws cli, ssh, local state
        │  AWS APIs (stacks 01-03)          SSH tunnel localhost:8443 / :9443 (stack 04)
        │                                        │ EC2 Instance Connect Endpoint (TCP 22)
        ▼                                        ▼
             ORIGIN VPC (10.10.0.0/16)                  CACHE VPC (10.20.0.0/16)
  ┌───────────────────────────────────────┐   VPC peering   ┌───────────────────────────────────────┐
  │  helper EC2 ──► mgmt :443 (both sides)│─────────────────│                                       │
  │  FSx for ONTAP Origin                 │◄──intercluster─►│  FSx for ONTAP Cache                  │
  │   svm_origin / vol_origin (FlexGroup) │   TCP 11104/5   │   svm_cache / vol_cache (FlexCache)   │
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
│   ├── 04-fsxn-origin/         FSx for ONTAP Origin: FS + SVM + origin vol + SG          ✅ implemented
│   ├── 05-fsxn-cache/          FSx for ONTAP Cache: FS + SVM + SG (no volumes)           ✅ implemented
│   ├── 06-helper-ec2/          helper EC2 + EC2 Instance Connect Endpoint (no internet)  ✅ implemented
│   └── 07-ontap-flexcache/     cluster peer + SVM peer + FlexCache (ONTAP provider)      🔲 interface only
├── stacks/                     what you actually deploy – one local state file per stack
│   ├── 01-landing-zone/        Network Origin + Network Cache + peering                  ✅
│   ├── 02-fsxn/                FSx for ONTAP Origin and/or Cache + fsxadmin secret     ✅
│   ├── 03-helper/              helper EC2 (network hop to the ONTAP management API)      ✅
│   └── 04-flexcache/           ONTAP: peering + FlexCache volume                         wired
├── scripts/
│   ├── ontap-tunnel.sh         SSH tunnel Mac -> both mgmt IPs via the helper (--check = test)
│   ├── origin/                 dataset generation
│   └── cache/                  read benchmark
├── common.tfvars.example       project, creator, regions, AZs
└── tf.sh                       wrapper: ./tf.sh <stack> <command>
```

**Modules vs stacks:** a *module* is a building block ("how to build one FSxN"). A *stack* is a
deployable unit with its own state that calls modules ("build the origin FSxN, and the cache one if
enabled"). Stacks read each other's outputs from the local state files:

```
01-landing-zone ──► 02-fsxn ──────────┬──► 04-flexcache
        └─────────► 03-helper ─────────┘   (tunnel for the ONTAP API)
```

## Creation order

Stacks and modules are both numbered in the order they are created. A number only ever depends on
lower numbers, so deploy top-down and destroy bottom-up.

**Stacks** (each has its own state; deploy `01` → `04`, destroy `04` → `01`):

| # | Stack | Depends on | Calls modules |
|---|---|---|---|
| 01 | `01-landing-zone` | – | `01-network-origin`, `02-network-cache`, `03-vpc-peering` |
| 02 | `02-fsxn` | `01-landing-zone` (VPC, subnets, CIDRs) | `04-fsxn-origin`, `05-fsxn-cache` |
| 03 | `03-helper` | `01-landing-zone` (origin subnet); can run in parallel with `02-fsxn` | `06-helper-ec2` |
| 04 | `04-flexcache` | `02-fsxn` (both FSx for ONTAP, mgmt + intercluster IPs, shared fsxadmin secret) · `03-helper` (tunnel) | `07-ontap-flexcache` |

**Modules** (building blocks, in creation order):

| # | Module | Side | Needs (from lower numbers) | Used by stack |
|---|---|---|---|---|
| 01 | `01-network-origin` | Origin | – | `01-landing-zone` |
| 02 | `02-network-cache` | Cache | – (independent of 01, but must not overlap its CIDR) | `01-landing-zone` |
| 03 | `03-vpc-peering` | both | `01` + `02`: VPC IDs, route tables, CIDRs | `01-landing-zone` |
| 04 | `04-fsxn-origin` | Origin | `01`: VPC, private subnets · `03`: reachability for intercluster + mgmt | `02-fsxn` |
| 05 | `05-fsxn-cache` | Cache | `02`: VPC, private subnets · `03` · created after the Origin it caches (`04`) | `02-fsxn` |
| 06 | `06-helper-ec2` | Origin (Cache if no Origin) | `01`: subnet · reaches `04`/`05` management at run time | `03-helper` |
| 07 | `07-ontap-flexcache` | both | `04` + `05`: mgmt/intercluster IPs, origin volume · path via `06` | `04-flexcache` |

```
01-network-origin ──┐                  ┌──► 04-fsxn-origin ──┐
                    ├──► 03-vpc-peering┤                     ├──► 07-ontap-flexcache
02-network-cache  ──┘                  └──► 05-fsxn-cache  ──┘
01-network-origin ─────────────────────────► 06-helper-ec2 ───────(tunnel)──► 07
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
| helper EC2 | `pedro-flexcache-perf-helper`, `...-helper-eice`, `...-helper-sg`, `...-helper-root` |

The prefix is `<creator>-<project>` from `common.tfvars`, so `creator` may only contain lowercase
letters, digits and hyphens.

Also tagged: the VPC's default security group, main route table and default network ACL, which AWS
creates untagged (the network modules adopt them), and the helper's root EBS volume (`volume_tags`,
which `default_tags` don't reach).

Not taggable: routes and route-table associations (AWS has no tags for them), and ONTAP objects
in `07-ontap-flexcache` (cluster peer, SVM peer, FlexCache). The FlexCache volume gets an ONTAP
comment with the Creator instead.

## Why separate stacks

- **Deploy in steps.** Landing zone today, origin FSxN tomorrow, cache only if needed.
- **Small blast radius.** Rebuilding the FlexCache can never touch the FSxN or VPCs.
- **ONTAP provider needs real endpoints.** The netapp-ontap provider is configured with the FSxN
  management IPs, which must be known at plan time – so ONTAP config has to be a later stack.

## Origin, Cache or both

Two switches in `common.tfvars` decide which side exists. They are shared by every stack:

```hcl
deploy_origin = true
deploy_cache  = true
```

| What | Stack | `deploy_origin` | `deploy_cache` | Both |
|---|---|---|---|---|
| Network Origin (VPC, subnets) | `01-landing-zone` | ✅ | | ✅ |
| Network Cache (VPC, subnets) | `01-landing-zone` | | ✅ | ✅ |
| VPC peering Origin ⇄ Cache | `01-landing-zone` | | | ✅ only |
| FSx for ONTAP Origin | `02-fsxn` | ✅ | | ✅ |
| FSx for ONTAP Cache | `02-fsxn` | | ✅ | ✅ |
| Helper EC2 | `03-helper` | ✅ (origin VPC) | ✅ (cache VPC, only if no Origin) | ✅ (origin VPC) |
| FlexCache volume | `04-flexcache` | | | ✅ only |

- Always apply `01-landing-zone` before `02-fsxn` after changing a switch: a side's FSx for ONTAP
  needs that side's network. `02-fsxn` stops with a clear error if it isn't there.
- Switching a side on and re-applying **adds** it without touching the other side. Switching it off
  **destroys** that side (run `04-flexcache destroy` first if FlexCache is in use, then `02-fsxn`,
  then `01-landing-zone`).
- Both switches `false` is rejected.

## Your Mac

Everything runs from your Mac; there is no bastion host.

- **Tools:** `brew install hashicorp/tap/terraform awscli` (Terraform ≥ 1.10, AWS CLI v2). `ssh` and
  `jq` come with macOS (15+; otherwise `brew install jq`).
- **AWS credentials:** a profile that can create VPCs, peering, FSx for ONTAP, EC2, EC2 Instance
  Connect Endpoints and Secrets Manager secrets, and use `ec2-instance-connect:SendSSHPublicKey` /
  `OpenTunnel` (`export AWS_PROFILE=<profile>`; in a sandbox account `AdministratorAccess` is simplest).
- **Stacks 01–03** only call AWS APIs, so they work from anywhere with internet.
- **Stack 04 (FlexCache)** talks to the ONTAP REST API on both FSx for ONTAP **management IPs**, which
  are private. `scripts/ontap-tunnel.sh` opens an SSH tunnel from your Mac through the **EC2
  Instance Connect Endpoint** to the **helper EC2** (stack 03), forwarding `localhost:8443` to the
  Origin and `localhost:9443` to the Cache (over the peering). The helper only forwards these API
  calls: peering and FlexCache traffic flow cluster to cluster over the intercluster LIFs.
- **No internet in the VPCs:** no NAT, no internet gateway, no public IPs. The EICE is free and only
  allows SSH to the helper; EC2 Instance Connect pushes a 60-second key per session.

## Deploy (on your Mac)

```bash
git clone https://github.com/PFFernandes/flexcache-perf-testing.git && cd flexcache-perf-testing
cp common.tfvars.example common.tfvars                                   # regions, AZs, project, creator
export AWS_PROFILE=<your-profile>

# 1. landing zone
./tf.sh 01-landing-zone init && ./tf.sh 01-landing-zone apply

# 2. FSx for ONTAP – Origin and/or Cache, per deploy_origin / deploy_cache
./tf.sh 02-fsxn init && ./tf.sh 02-fsxn apply
#    e.g. Origin first: deploy_cache = false, apply 01 + 02; later set it to true and apply 01 + 02 again

# 3. helper EC2 (can run in parallel with step 2)
./tf.sh 03-helper init && ./tf.sh 03-helper apply
./scripts/ontap-tunnel.sh --check                  # tests the path: GET /api/cluster on both FSx for ONTAP

# 4. FlexCache (needs both FSx for ONTAP and the tunnel)
./scripts/ontap-tunnel.sh                          # terminal 1: keep it running
./tf.sh 04-flexcache init && ./tf.sh 04-flexcache apply   # terminal 2
```

> Tip: keep `deploy_origin` / `deploy_cache` in `common.tfvars` rather than passing `-var`, so a
> later plain `apply` doesn't switch a side back off.

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
./tf.sh 03-helper destroy
./tf.sh 02-fsxn destroy
./tf.sh 01-landing-zone destroy
```

## Network notes

- **Availability Zones** are set in `common.tfvars` as letters added to the region:
  `origin_azs = ["a"]` and `cache_azs = ["a"]` (default `<region>a`, e.g. `eu-west-1a`). Each AZ gets
  one private /24 (`x.x.1.0`, `x.x.2.0`, ...), and the first AZ also gets one public /24 (`x.x.101.0`)
  when NAT is on. Single-AZ FSx for ONTAP uses the first AZ. Multi-AZ FSx for ONTAP
  needs two, e.g. `["a", "b"]`; `02-fsxn` stops with an error otherwise.
- VPC CIDRs must not overlap (defaults: origin `10.10.0.0/16`, cache `10.20.0.0/16`).
- FlexCache and cluster peering use the FSxN **intercluster** endpoints (IPs inside the VPC), which
  route over the origin ⇄ cache peering.
- **Single-AZ** FSxN is the default: its management endpoint is an IP inside the VPC, so the helper
  reaches it (the cache one over the peering). Multi-AZ
  management/NFS endpoints use floating IPs that don't route over peering (would need Transit Gateway).

## Cost reminders

FSxN is billed per hour for throughput capacity + SSD. Destroy `02-fsxn` between test campaigns.
The helper (`t4g.small`) costs about USD 0.02/h and the EICE is free; destroy `03-helper` or stop the
instance when you're not configuring.
