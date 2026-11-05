# FlexCache performance testing on FSx for NetApp ONTAP

Terraform automation to build an origin/cache FSx for ONTAP (FSxN) environment and measure
FlexCache read performance. Everything is split into **layers you deploy one at a time**,
**Origin, Cache or both** can be deployed (two switches in `common.tfvars`), and everything runs
from **your Mac**, where the Terraform state stays. No bastion host and no EC2 instances.

```
   YOUR MAC: git, terraform, aws cli, local state
        │  AWS APIs (stacks 01-02)          ONTAP REST API to both mgmt IPs (stack 03, needs a VPN path)
        ▼                                        ▼
             ORIGIN VPC (10.10.0.0/16)                  CACHE VPC (10.20.0.0/16)
  ┌───────────────────────────────────────┐   VPC peering   ┌───────────────────────────────────────┐
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
│   └── 06-ontap-flexcache/     cluster peer + SVM peer + FlexCache (ONTAP provider)      🔲 interface only
├── stacks/                     what you actually deploy – one local state file per stack
│   ├── 01-landing-zone/        Network Origin + Network Cache + peering                  ✅
│   ├── 02-fsxn/                FSx for ONTAP Origin and/or Cache + fsxadmin secret     ✅
│   └── 03-flexcache/           ONTAP: peering + FlexCache volume                         wired
├── scripts/
│   ├── origin/                 dataset generation
│   └── cache/                  read benchmark
├── common.tfvars.example       project, creator, regions, AZs
└── tf.sh                       wrapper: ./tf.sh <stack> <command>
```

**Modules vs stacks:** a *module* is a building block ("how to build one FSxN"). A *stack* is a
deployable unit with its own state that calls modules ("build the origin FSxN, and the cache one if
enabled"). Stacks read each other's outputs from the local state files:

```
01-landing-zone ──► 02-fsxn ──► 03-flexcache
```

## Creation order

Stacks and modules are both numbered in the order they are created. A number only ever depends on
lower numbers, so deploy top-down and destroy bottom-up.

**Stacks** (each has its own state; deploy `01` → `03`, destroy `03` → `01`):

| # | Stack | Depends on | Calls modules |
|---|---|---|---|
| 01 | `01-landing-zone` | – | `01-network-origin`, `02-network-cache`, `03-vpc-peering` |
| 02 | `02-fsxn` | `01-landing-zone` (VPC, subnets, CIDRs) | `04-fsxn-origin`, `05-fsxn-cache` |
| 03 | `03-flexcache` | `02-fsxn` (both FSx for ONTAP, mgmt + intercluster IPs, shared fsxadmin secret) | `06-ontap-flexcache` |

**Modules** (building blocks, in creation order):

| # | Module | Side | Needs (from lower numbers) | Used by stack |
|---|---|---|---|---|
| 01 | `01-network-origin` | Origin | – | `01-landing-zone` |
| 02 | `02-network-cache` | Cache | – (independent of 01, but must not overlap its CIDR) | `01-landing-zone` |
| 03 | `03-vpc-peering` | both | `01` + `02`: VPC IDs, route tables, CIDRs | `01-landing-zone` |
| 04 | `04-fsxn-origin` | Origin | `01`: VPC, private subnets · `03`: reachability for intercluster + mgmt | `02-fsxn` |
| 05 | `05-fsxn-cache` | Cache | `02`: VPC, private subnets · `03` · created after the Origin it caches (`04`) | `02-fsxn` |
| 06 | `06-ontap-flexcache` | both | `04` + `05`: mgmt/intercluster IPs, origin volume | `03-flexcache` |

```
01-network-origin ──┐                  ┌──► 04-fsxn-origin ──┐
                    ├──► 03-vpc-peering┤                     ├──► 06-ontap-flexcache
02-network-cache  ──┘                  └──► 05-fsxn-cache  ──┘
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

The prefix is `<creator>-<project>` from `common.tfvars`, so `creator` may only contain lowercase
letters, digits and hyphens.

Also tagged: the VPC's default security group, main route table and default network ACL, which AWS
creates untagged (the network modules adopt them).

Not taggable: routes and route-table associations (AWS has no tags for them), and ONTAP objects
in `06-ontap-flexcache` (cluster peer, SVM peer, FlexCache). The FlexCache volume gets an ONTAP
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
| FlexCache volume | `03-flexcache` | | | ✅ only |

- Always apply `01-landing-zone` before `02-fsxn` after changing a switch: a side's FSx for ONTAP
  needs that side's network. `02-fsxn` stops with a clear error if it isn't there.
- Switching a side on and re-applying **adds** it without touching the other side. Switching it off
  **destroys** that side (run `03-flexcache destroy` first if FlexCache is in use, then `02-fsxn`,
  then `01-landing-zone`).
- Both switches `false` is rejected.

## Your Mac

Everything runs from your Mac; there is no bastion host.

- **Tools:** `brew install hashicorp/tap/terraform awscli` (Terraform ≥ 1.10, AWS CLI v2).
- **AWS credentials:** a profile that can create VPCs, peering, FSx for ONTAP and Secrets Manager
  secrets (`export AWS_PROFILE=<profile>`; in a sandbox account `AdministratorAccess` is simplest).
- **Stacks 01 and 02** only call AWS APIs, so they work from anywhere with internet.
- **Stack 03 (FlexCache)** talks to the ONTAP REST API on both FSx for ONTAP **management IPs**, which
  are private. Your Mac needs a network path into the VPCs for it, e.g. AWS Client VPN into the
  origin VPC (the cache one is reached over the peering). Not part of this repo yet.
- No NAT gateway is needed: FSx for ONTAP never initiates internet traffic (NAT is off by default).

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

# 3. FlexCache (needs both FSx for ONTAP and a network path to their management IPs)
./tf.sh 03-flexcache init && ./tf.sh 03-flexcache apply
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
./tf.sh 03-flexcache destroy     # removes FlexCache + peering first (needs the path to the mgmt IPs)
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
- **Single-AZ** FSxN is the default: its management endpoint is an IP inside the VPC, reachable
  over the peering and a VPN into the VPC. Multi-AZ
  management/NFS endpoints use floating IPs that don't route over peering (would need Transit Gateway).

## Cost reminders

FSxN is billed per hour for throughput capacity + SSD. Destroy `02-fsxn` between test campaigns.
