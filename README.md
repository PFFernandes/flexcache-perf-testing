# FlexCache performance testing on FSx for NetApp ONTAP

Terraform automation that builds an **FSx for ONTAP Origin** and an **FSx for ONTAP Cache**, connects
them with **FlexCache**, and adds a Linux test client on each side to measure read performance.

- **Layers you deploy one at a time:** four stacks, each with its own state.
- **Origin, Cache or both:** two switches in `common.tfvars`.
- **Runs from your Mac:** the Terraform state stays there. There is no bastion host, and the VPCs
  have no internet access, NAT gateway or public IPs.

```
  YOUR MAC  ── terraform, aws cli, local state
     │  AWS APIs: stacks 01, 02, 04
     │  ONTAP REST API to both management IPs: stack 03 (needs a network path, e.g. VPN)
     │  login to the clients: EC2 Instance Connect or SSM
     ▼
          ORIGIN VPC  10.10.0.0/16                           CACHE VPC  10.20.0.0/16
  ┌──────────────────────────────────────┐            ┌──────────────────────────────────────┐
  │ FSx for ONTAP Origin                 │  peering   │ FSx for ONTAP Cache                  │
  │   svm_origin / vol_origin (FlexGroup)│◄──────────►│   svm_cache / vol_cache (FlexCache)  │
  │          ▲ NFS                       │intercluster│          ▲ NFS                       │
  │ EC2 origin client                    │TCP 11104/5 │ EC2 cache client                     │
  │   /mnt/fsxn/vol_origin               │            │   /mnt/fsxn/vol_cache (+ vol_origin) │
  └──────────────────────────────────────┘            └──────────────────────────────────────┘
          origin_region                                     cache_region (same or different)
```

## Status

| Stack | What it deploys | Status |
|---|---|---|
| `01-landing-zone` | Network Origin, Network Cache, VPC peering | ✅ ready |
| `02-fsxn` | FSx for ONTAP Origin and Cache, shared fsxadmin secret | ✅ ready |
| `03-flexcache` | Cluster peer, SVM peer, FlexCache volume | 🔲 not built yet: module `06-ontap-flexcache` has no resources, and your Mac needs a path to the management IPs |
| `04-ec2` | Linux test client on the Origin and/or Cache | ✅ ready |

Nothing here has been applied to AWS yet; every stack is checked with `terraform validate` and
offline tests with a mocked AWS provider.

## Repository layout

```
.
├── modules/                   building blocks (no backend, no provider config)
│   ├── 01-network-origin/     origin VPC, private subnets, S3 endpoint, optional NAT
│   ├── 02-network-cache/      cache VPC, same as 01
│   ├── 03-vpc-peering/        peering + routes, same- or cross-region
│   ├── 04-fsxn-origin/        FSx for ONTAP Origin: file system, SVM, vol_origin, security group
│   ├── 05-fsxn-cache/         FSx for ONTAP Cache: file system, SVM, security group
│   ├── 06-ontap-flexcache/    cluster peer, SVM peer, FlexCache volume (ONTAP provider)
│   └── 07-ec2-client/         Linux client: NFS mounts, EC2 Instance Connect + SSM endpoints
├── stacks/                    what you deploy, one local state file each
│   ├── 01-landing-zone/
│   ├── 02-fsxn/
│   ├── 03-flexcache/
│   └── 04-ec2/
├── scripts/
│   ├── origin/                dataset generation (planned)
│   └── cache/                 read benchmark (planned)
├── common.tfvars.example      settings shared by every stack
└── tf.sh                      wrapper: ./tf.sh <stack> <command>
```

A **module** is a building block ("how to build one FSx for ONTAP"). A **stack** is something you
deploy, with its own state, that calls modules ("build the Origin, and the Cache if switched on").
Stacks read the outputs of earlier stacks from their local state files.

## Creation order

Stacks and modules are numbered in the order they are created. A number only depends on lower
numbers, so deploy from `01` upwards and destroy from the highest number down.

```
stacks:   01-landing-zone ──► 02-fsxn ──┬──► 03-flexcache
                                        └──► 04-ec2      (vol_cache mount needs 03)

modules:  01-network-origin ──┐                ┌──► 04-fsxn-origin ──┐
                              ├──► 03-peering ─┤                     ├──► 06-ontap-flexcache
          02-network-cache  ──┘                └──► 05-fsxn-cache  ──┘
          04 / 05 / 06 ──(NFS)──► 07-ec2-client
```

| # | Stack | Reads from | Calls modules |
|---|---|---|---|
| 01 | `01-landing-zone` | – | `01-network-origin`, `02-network-cache`, `03-vpc-peering` |
| 02 | `02-fsxn` | 01: VPCs, subnets, CIDRs | `04-fsxn-origin`, `05-fsxn-cache` |
| 03 | `03-flexcache` | 02: management and intercluster IPs, SVMs, fsxadmin secret | `06-ontap-flexcache` |
| 04 | `04-ec2` | 01: subnets · 02: SVM NFS IPs, junction paths | `07-ec2-client` |

`04-ec2` can be applied before `03-flexcache`: the cache client's `vol_cache` mount simply waits
until the FlexCache volume exists (it mounts on first access).

| # | Module | Side | Needs |
|---|---|---|---|
| 01 | `01-network-origin` | Origin | – |
| 02 | `02-network-cache` | Cache | – (its CIDR must not overlap 01) |
| 03 | `03-vpc-peering` | both | 01 + 02: VPC IDs, route tables, CIDRs |
| 04 | `04-fsxn-origin` | Origin | 01: VPC and subnet · 03: reachability |
| 05 | `05-fsxn-cache` | Cache | 02: VPC and subnet · 03 · the Origin it caches (04) |
| 06 | `06-ontap-flexcache` | both | 04 + 05: management/intercluster IPs, origin volume |
| 07 | `07-ec2-client` | both | 01/02: the FSx for ONTAP subnet · 04/05: SVM NFS IP · 06: FlexCache path |

## Settings

Module variables are never set directly: each stack fills them in. You only edit these files
(all git-ignored; copy them from the `.example` next to them):

| File | Main settings |
|---|---|
| `common.tfvars` (every stack) | `project`, `creator`, `origin_region`, `cache_region`, `deploy_origin`, `deploy_cache`, `origin_azs`, `cache_azs` |
| `stacks/01-landing-zone/terraform.tfvars` | VPC CIDRs, subnet CIDR overrides, `origin_nat_gateway` / `cache_nat_gateway` (default `false`) |
| `stacks/02-fsxn/terraform.tfvars` | `origin_fsxn` / `cache_fsxn` (default SINGLE_AZ_1, 128 MB/s, 1024 GiB), `origin_volume` (default `vol_origin`, FlexGroup, 800 GiB, storage efficiency on) |
| `stacks/03-flexcache/terraform.tfvars` | `flexcache_name` (`vol_cache`), `flexcache_size_gib` (500), `flexcache_junction_path`, `cache_aggregates` |
| `stacks/04-ec2/terraform.tfvars` | `origin_ec2` / `cache_ec2`, `instance_type` (`t3.small`), `enable_eice` / `enable_ssm`, `nfs_options`, `cache_mounts_origin` |

The stack files are optional; without them every value has a default. `tf.sh` passes
`common.tfvars` to every stack and, before each plan or apply, prints the files it loads and the
regions it uses. The `.example` files themselves are never read.

## Origin, Cache or both

```hcl
# common.tfvars
deploy_origin = true
deploy_cache  = true
```

| What | Stack | Origin only | Cache only | Both |
|---|---|---|---|---|
| Network Origin | `01-landing-zone` | ✅ | | ✅ |
| Network Cache | `01-landing-zone` | | ✅ | ✅ |
| VPC peering | `01-landing-zone` | | | ✅ |
| FSx for ONTAP Origin | `02-fsxn` | ✅ | | ✅ |
| FSx for ONTAP Cache | `02-fsxn` | | ✅ | ✅ |
| FlexCache volume | `03-flexcache` | | | ✅ |
| EC2 client (also `origin_ec2` / `cache_ec2`) | `04-ec2` | origin client | cache client | both |

- After changing a switch, apply the stacks in order (`01`, then `02`, then `04`): each side needs
  its network first. `02-fsxn` and `04-ec2` stop with a clear error if something is missing.
- Switching a side **on** adds it without touching the other side. Switching it **off** destroys
  that side, so remove what depends on it first (`04-ec2`, `03-flexcache`, then `02-fsxn`, then
  `01-landing-zone`).
- Both switches `false` is rejected.
- Keep the switches in `common.tfvars` rather than passing `-var`, so a later plain `apply` doesn't
  switch a side back off.

## Your Mac

- **Tools:** `brew install hashicorp/tap/terraform awscli` (Terraform ≥ 1.10, AWS CLI v2). For SSM
  logins also `brew install --cask session-manager-plugin`.
- **AWS credentials:** `export AWS_PROFILE=<profile>`. The profile must be able to create VPCs,
  peering, FSx for ONTAP, EC2 instances and endpoints, IAM roles and Secrets Manager secrets. In a
  sandbox account `AdministratorAccess` is simplest (`PowerUserAccess` can't create the IAM role).
- **Stacks 01, 02 and 04** only call AWS APIs, so they work from anywhere with internet.
- **Stack 03** talks to the ONTAP REST API on both FSx for ONTAP management IPs, which are private.
  Your Mac needs a network path into the VPCs for it (e.g. AWS Client VPN into the origin VPC; the
  cache one is reached over the peering). That path is not part of this repo yet.

## Deploy

```bash
git clone https://github.com/PFFernandes/flexcache-perf-testing.git
cd flexcache-perf-testing
cp common.tfvars.example common.tfvars          # edit project, creator, regions, switches, AZs
export AWS_PROFILE=<your-profile>
```

```bash
# 1. networks
./tf.sh 01-landing-zone init && ./tf.sh 01-landing-zone apply

# 2. FSx for ONTAP Origin and/or Cache (about 20-40 minutes each, billed hourly)
./tf.sh 02-fsxn init && ./tf.sh 02-fsxn apply

# 3. FlexCache (not built yet, see Status)
./tf.sh 03-flexcache init && ./tf.sh 03-flexcache apply

# 4. EC2 clients
./tf.sh 04-ec2 init && ./tf.sh 04-ec2 apply
./tf.sh 04-ec2 output                           # login commands and mount points
```

## The EC2 clients

Each client is an Amazon Linux 2023 instance in the **same private subnet as its side's FSx for
ONTAP**. At boot it adds the NFS mounts to `/etc/fstab` (systemd automount, mounted on first access):

| Client | Mounts |
|---|---|
| origin | `/mnt/fsxn/vol_origin` ← origin SVM `:/vol_origin` |
| cache | `/mnt/fsxn/vol_cache` ← cache SVM `:/vol_cache` (FlexCache) · `/mnt/fsxn/vol_origin` ← origin SVM over the peering, as a no-cache baseline |

Default NFS options: `vers=3,nconnect=8,hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576`
(change with `nfs_options`).

Log in from your Mac (the exact commands are in `./tf.sh 04-ec2 output`):

```bash
aws ec2-instance-connect ssh --instance-id <id> --connection-type eice   # EC2 Instance Connect Endpoint
aws ssm start-session --target <id>                                      # SSM Session Manager
```

Both endpoints are created per VPC by `07-ec2-client`. The Instance Connect Endpoint may only SSH to
the client; the SSM interface endpoints only accept HTTPS from it. `t3.small` is enough to check the
mounts; use a network-optimised type such as `c6in.xlarge` for real performance numbers.

## Tags and names

Every AWS resource gets two tags: `Creator` (from `creator`, set through the provider
`default_tags`) and `Name`. Every name is `<creator>-<project>-<side>-<object>`:

| Object | Name |
|---|---|
| VPC, subnets | `pedro-flexcache-perf-origin-vpc`, `pedro-flexcache-perf-origin-private-eu-west-1a` |
| Route tables, NAT | `...-origin-private-rt`, `...-origin-nat`, `...-origin-nat-eip` |
| Peering | `pedro-flexcache-perf-origin-to-cache` |
| FSx for ONTAP | `pedro-flexcache-perf-origin-fsxn`, security group `...-origin-fsxn-sg` |
| fsxadmin secret | `pedro-flexcache-perf/fsxadmin` |
| EC2 clients | `pedro-flexcache-perf-origin-client`, `...-origin-client-eice`, `...-origin-client-ssm-endpoint`, `...-cache-client` |

`creator` may only contain lowercase letters, digits and hyphens, because it is part of every name.

- **Also tagged:** each VPC's default security group, main route table and network ACL (AWS creates
  them untagged; the network modules adopt them), and the clients' root EBS volumes.
- **Not taggable:** routes and route-table associations, and the ONTAP objects of
  `06-ontap-flexcache` (the FlexCache volume will carry an ONTAP comment with the Creator instead).

## State and the fsxadmin password

Each stack writes `stacks/<stack>/terraform.tfstate` on your Mac (git-ignored). It contains the
generated fsxadmin password, so never commit it.

- **One fsxadmin password** for both FSx for ONTAP: `02-fsxn` generates it and stores it in the
  Secrets Manager secret `<creator>-<project>/fsxadmin` in the origin region. To read it:
  `aws secretsmanager get-secret-value --secret-id <creator>-<project>/fsxadmin --region <origin_region>`
- **Keep the state files.** Destroy the lab before you delete the clone, and back the `*.tfstate`
  files up (e.g. Time Machine). Without them Terraform no longer knows what it created.
- Moving to S3 later is a one-file change per stack (`backend.tf`) plus `terraform init -migrate-state`.

## Destroy

```bash
./tf.sh 04-ec2 destroy
./tf.sh 03-flexcache destroy        # needs the path to the management IPs
./tf.sh 02-fsxn destroy
./tf.sh 01-landing-zone destroy
```

## Network notes

- **Availability Zones** are letters added to the region in `common.tfvars`: `origin_azs = ["a"]`
  and `cache_azs = ["a"]` (default `eu-west-1a`). Each AZ gets one private /24 (`x.x.1.0`,
  `x.x.2.0`, ...). Single-AZ FSx for ONTAP and the EC2 clients use the first AZ; Multi-AZ needs
  two, e.g. `["a", "b"]`.
- **CIDRs** must not overlap (defaults: origin `10.10.0.0/16`, cache `10.20.0.0/16`).
- **No NAT gateway is needed** (off by default): FSx for ONTAP never starts internet traffic, the
  clients reach SSM through the interface endpoints and Amazon Linux packages through the free S3
  gateway endpoint. With NAT on, the first AZ also gets a public /24 (`x.x.101.0`).
- **Security groups** on both FSx for ONTAP allow, from both VPCs: NFS (TCP/UDP 111, 635, 2049,
  4045-4046, UDP 4049), ONTAP management (TCP 443, 22), intercluster (TCP 11104-11105) and ICMP.
- **Cluster peering and FlexCache** use the intercluster IPs and run over the VPC peering.
- **Single-AZ is the default** because its management and NFS endpoints are normal VPC IPs that
  work across peering. Multi-AZ endpoints use floating IPs that don't route over peering (they
  would need Transit Gateway).

## Costs

- **FSx for ONTAP** is billed per hour for throughput capacity and SSD: destroy `02-fsxn` between
  test campaigns.
- **EC2 clients:** `t3.small` is about USD 0.02/h each.
- **SSM endpoints:** about USD 0.03/h per VPC for the three of them (`enable_ssm = false` to skip).
- **EC2 Instance Connect Endpoint:** free.
