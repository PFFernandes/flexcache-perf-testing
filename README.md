# FlexCache performance testing on FSx for NetApp ONTAP

Terraform automation that builds an **FSx for ONTAP Origin** and an **FSx for ONTAP Cache**, adds a
test client on each side, and connects the two file systems with **FlexCache**.

- **Layers you deploy one at a time:** four lab stacks (01-04), each with its own state, plus the
  optional test bench (00 and 05).
- **Origin, Cache or both:** two switches in `common.tfvars`.
- **NFS or SMB:** `protocol` in `common.tfvars`. NFS (default) uses Linux clients; SMB adds an AWS
  Managed Microsoft AD, Windows clients and the shares `origin` and `cache`.
- **Runs from one operator machine** (Linux or macOS): the Terraform state stays there. There is no bastion host and no VPN; the
  VPCs have no internet access, NAT gateway or public IPs.
- **FlexCache is configured from the origin client:** Terraform sends it a script with SSM
  Run Command, and the client creates the cluster peer, SVM peer and FlexCache volume through the
  ONTAP REST API.
- **Optional test bench** ([details](#test-bench-stack-05)): commands on the clients to create
  datasets by hand (six t-shirt sizes, 10 GiB to 300 GiB), and the OpenTelemetry Collector on both
  clients recording host, NFS and network metrics onto a results volume (`vol_bench`, FSx for
  ONTAP) that FSx backs up when the lab is destroyed.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/architecture-dark.svg">
  <img src="docs/architecture-light.svg" alt="Architecture: the operator machine runs Terraform against AWS; the origin VPC holds the FSx for ONTAP Origin (vol_origin) and the origin EC2 client, the cache VPC holds the FSx for ONTAP Cache (vol_cache, the FlexCache) and the cache EC2 client; the VPCs are peered and FlexCache data flows between the file systems over TCP 11104-11105.">
</picture>

<details>
<summary>Text version of the diagram</summary>

```
  OPERATOR MACHINE  ── terraform, aws cli, local state
     │  AWS APIs (all stacks), SSM Run Command (stack 04)
     │  login to the clients: EC2 Instance Connect or SSM
     ▼
          ORIGIN VPC  10.10.0.0/16                           CACHE VPC  10.20.0.0/16
  ┌──────────────────────────────────────┐            ┌──────────────────────────────────────┐
  │ FSx for ONTAP Origin                 │  peering   │ FSx for ONTAP Cache                  │
  │   svm-origin / vol_origin (FlexGroup)│◄──────────►│   svm-cache / vol_cache (FlexCache)  │
  │          ▲ NFS     ▲ ONTAP REST      │intercluster│          ▲ NFS     ▲ ONTAP REST      │
  │ EC2 origin client ─┴─────────────────┼────────────┼────────────────────┘                 │
  │   /mnt/fsxn/vol_origin               │TCP 11104/5 │ EC2 cache client                     │
  │   runs the FlexCache configuration   │            │   /mnt/fsxn/vol_cache                │
  └──────────────────────────────────────┘            └──────────────────────────────────────┘
          origin_region                                     cache_region (same or different)
```

</details>

## Status

| Stack | What it deploys | Status |
|---|---|---|
| `00-bench-store` (optional, once) | Package bucket(s) that deliver the OpenTelemetry Collector to the clients (no results) | 🧪 not yet run on AWS |
| `01-landing-zone` | Network Origin, Network Cache, VPC peering | ✅ ready |
| `02-fsxn` | FSx for ONTAP Origin and Cache, shared fsxadmin secret | ✅ ready |
| `03-ec2` | Test client on the Origin and/or Cache (Linux for NFS, Windows for SMB) | ✅ ready |
| `04-flexcache` | Cluster peer, SVM peer, FlexCache volume, SMB shares (run on the origin client) | ✅ ready |
| `05-bench` (optional) | Test bench on the Linux clients: `bench-dataset`, `bench-datasets-nfs` (datasets tested on AWS); results volume `vol_bench` and the OpenTelemetry Collector + bench-probe writing to it (not yet run on AWS). Users create the datasets by hand ([Test bench](#test-bench-stack-05)) | 🧪 partly tested |
| SMB option | Managed AD (01), domain-joined SVMs (02), Windows clients (03), shares (04) | 🧪 not yet run on AWS |

The NFS lab has been deployed on AWS. Every stack passes `terraform validate` and offline tests with
a mocked AWS provider, for both protocols; the Linux FlexCache script was also tested against a
simulated ONTAP REST API. The test bench's dataset commands have been run on AWS against the NFS
lab; its results volume and telemetry have only been tested offline so far. The SMB path has not run on AWS yet, and its PowerShell scripts (Windows
FlexCache configuration and share mapping) have not been executed anywhere.

## Run the whole lab, step by step

Everything below runs on the operator machine, from the repository folder (see
[Operator machine](#operator-machine) for the tools).

### 1. Get the code and the tools

```bash
git clone https://github.com/PFFernandes/flexcache-perf-testing.git
cd flexcache-perf-testing
```

Install Terraform ≥ 1.10, the AWS CLI v2 and, for SSM logins to the EC2 clients, the Session
Manager plugin, with your platform's package manager or the vendors' installers:
[Terraform](https://developer.hashicorp.com/terraform/install),
[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

### 2. Log in to AWS

```bash
aws configure sso                               # once: creates a profile, e.g. "flexcache"
aws sso login --profile flexcache               # whenever the session expires
export AWS_PROFILE=flexcache                    # in every terminal you use
aws sts get-caller-identity                     # must print your account
```

(With access keys instead of SSO: `aws configure --profile flexcache`.)

### 3. Create and edit the settings files

```bash
./scripts/init-tfvars.sh
```

This creates `common.tfvars` and `stacks/<stack>/terraform.tfvars` for every stack from the
`.example` files. It never overwrites a file that already exists (`--force` recreates them and
keeps a `.bak`). Then edit at least `common.tfvars`:

| Setting | Example |
|---|---|
| `creator` | `"pedro"` (lowercase, digits, hyphens; starts every name) |
| `project` | `"flexcache-perf"` |
| `origin_region` / `cache_region` | `"eu-west-1"` |
| `deploy_origin` / `deploy_cache` | `true` / `true` (FlexCache needs both) |
| `protocol` | `"nfs"` (default) or `"smb"`, see [NFS or SMB](#nfs-or-smb) |
| `origin_azs` / `cache_azs` | `["a"]` (= eu-west-1a) |

Sizes and options of each stack are in its own `terraform.tfvars` (see [Settings](#settings)).

### 4. Deploy the stacks in order

Each stack: `init` once, then `plan` to review and save the plan, then `apply-plan` to apply exactly that plan (type `yes` to
confirm). If anything changed in between, Terraform stops with `Saved plan is stale`: run `plan` again.
Plain `apply` also works; it makes a fresh plan and asks for confirmation. The saved `terraform.tfplan`
stays out of Git and is deleted after a successful `apply-plan`. It can hold the fsxadmin password, so don't share it. Every plan
or apply first prints the settings files it loaded, so check the regions there.

| # | Commands | Creates | Time |
|---|---|---|---|
| 0 (once, optional) | `./tf.sh 00-bench-store init`<br>`./tf.sh 00-bench-store plan`<br>`./tf.sh 00-bench-store apply-plan` | Package bucket (origin region), plus one in `cache_region` if different, that delivers the Collector to the clients. No results. Applied once per account; left in place between labs | ~1 min |
| 1 | `./tf.sh 01-landing-zone init`<br>`./tf.sh 01-landing-zone plan`<br>`./tf.sh 01-landing-zone apply-plan` | Origin and Cache VPCs, subnets, S3 endpoint, peering; SMB: Managed AD | ~2 min; SMB: +20-45 min |
| 2 | `./tf.sh 02-fsxn init`<br>`./tf.sh 02-fsxn plan`<br>`./tf.sh 02-fsxn apply-plan` | FSx for ONTAP Origin + Cache, SVMs, `vol_origin`, fsxadmin secret | 20-40 min, billed hourly |
| 3 | `./tf.sh 03-ec2 init`<br>`./tf.sh 03-ec2 plan`<br>`./tf.sh 03-ec2 apply-plan` | origin and cache EC2 clients (Windows for SMB), Instance Connect + SSM endpoints | ~5 min; Windows ~10 min |
| 4 | `./tf.sh 04-flexcache init`<br>`./tf.sh 04-flexcache plan`<br>`./tf.sh 04-flexcache apply-plan` | Secrets Manager endpoint, then on the origin client: cluster peer, SVM peer, `vol_cache`; SMB: shares `origin` and `cache` | ~5-10 min |
| 5 (optional) | `./tf.sh 05-bench init`<br>`./tf.sh 05-bench plan`<br>`./tf.sh 05-bench apply-plan` | Test bench on the Linux clients (NFS only): `/opt/bench`, `bench-dataset`, `bench-datasets-nfs`, `bench-results-sync`; with `telemetry = true` (needs step 0) the results volume `vol_bench` on the origin FSx, mounted on both clients, and the OpenTelemetry Collector and bench-probe writing to it; with `cloudwatch = true` also a CloudWatch endpoint per client VPC and the lab's CloudWatch dashboard. Creates no datasets | ~1 min; ~5 min with telemetry |

During step 4 the apply prints the log of the origin client, e.g.
`[flexcache] creating cluster peer ...`, `SVM peer state: peered`, `FlexCache vol_cache created`.
Check what each stack created at any time with `./tf.sh <stack> output`.

### 5. Log in to the clients and check the mounts

```bash
./tf.sh 03-ec2 output                           # instance IDs and the exact login commands
aws ec2-instance-connect ssh --instance-id <origin-client-id> --connection-type eice
```

On the origin client (volume root is owned by root, hence `sudo`):

```bash
df -h /mnt/fsxn/vol_origin                      # FSx for ONTAP Origin
sudo touch /mnt/fsxn/vol_origin/hello && ls -l /mnt/fsxn/vol_origin
```

On the cache client:

```bash
df -h /mnt/fsxn/vol_cache                       # FSx for ONTAP Cache, up to a minute after step 4
ls -l /mnt/fsxn/vol_cache                       # shows "hello", served through the cache
```

With `protocol = "smb"` the clients are Windows. Open an RDP tunnel through the Instance Connect
Endpoint (the exact command is `connect_eice` in `./tf.sh 03-ec2 output`), then connect your RDP
client to `localhost:13389` as `FLEXCACHE\Admin`, with the AD Admin password. The clients join the
domain a few minutes after boot (one extra restart). Until then, or if the join fails, use
`connect_ssm` (a PowerShell session) and read `C:\fsxn\fsxn-map.log`. With `domain_join = false`
log in as the local `Administrator`, which then gets the AD Admin password:

```bash
aws ec2-instance-connect open-tunnel --instance-id <id> --remote-port 3389 --local-port 13389
aws secretsmanager get-secret-value --secret-id <creator>-<project>/ad-admin --query SecretString --output text
```

The origin client shows the `origin` share as `O:`, the cache client the `cache` share as `X:` (up
to a minute after step 4). The mapping log is `C:\fsxn\fsxn-map.log`.

### 6. Create the datasets (by hand)

Optional, with stack 05 and `protocol = "nfs"`. Nothing creates datasets automatically: a user logs
in to the origin client and runs the commands, for example:

```bash
bench-datasets-nfs --dry-run small medium          # what would be written, and does it fit
bench-datasets-nfs --background small medium       # write them; keeps running after you log out
```

With telemetry on (stack 00 applied, `telemetry = true` in stack 05), the clients record host, NFS
and network metrics the whole time, and all of it, with each dataset's records, goes to the results
volume `/mnt/fsxn/vol_bench`.
The whole procedure is in [Test bench](#test-bench-stack-05).

### 7. Tear everything down

When you're done (FSx for ONTAP is billed every hour), destroy in reverse order. See
[Destroy](#destroy).

## Repository layout

```
.
├── modules/                   building blocks (no backend, no provider config)
│   ├── 01-network-origin/     origin VPC, private subnets, S3 endpoint, optional NAT
│   ├── 02-network-cache/      cache VPC, same as 01
│   ├── 03-vpc-peering/        peering + routes, same- or cross-region
│   ├── 04-managed-ad/         AWS Managed Microsoft AD (protocol = "smb" only)
│   ├── 05-fsxn-origin/        FSx for ONTAP Origin: file system, SVM, vol_origin, security group
│   ├── 06-fsxn-cache/         FSx for ONTAP Cache: file system, SVM, security group
│   ├── 07-ec2-client/         Linux (NFS mounts) or Windows (SMB drives) client, Instance Connect + SSM endpoints
│   ├── 08-ontap-flexcache/    FlexCache setup run on the origin client (SSM + ONTAP REST script, shares for SMB)
│   ├── 09-bench-deploy/       copies the test bench to the Linux clients over SSM
│   ├── 10-bench-store/        one package bucket (delivers the Collector; no results)
│   ├── 11-bench-telemetry/    mounts vol_bench; OpenTelemetry Collector + bench-probe writing to it
│   ├── 12-bench-results-volume/  vol_bench: the results volume, with a final backup on delete
│   ├── 13-bench-cloudwatch/   CloudWatch endpoint + PutMetricData for one client VPC
│   └── 14-bench-dashboard/    the lab's CloudWatch dashboard (bench + FSx + EC2 metrics)
├── stacks/                    what you deploy, one local state file each
│   ├── 00-bench-store/        optional, once per account: the package bucket(s)
│   ├── 01-landing-zone/
│   ├── 02-fsxn/
│   ├── 03-ec2/
│   ├── 04-flexcache/
│   └── 05-bench/              optional: the test bench on the clients
├── bench/                     test bench code (Python, standard library only)
│   ├── dataset/               module 1: create, modify, verify and delete datasets
│   ├── scripts/               bench-datasets-nfs (t-shirt size datasets)
│   ├── telemetry/             bench-probe: NFS, ENA and ping metrics for the Collector
│   └── tests/
├── profiles/datasets/         dataset specs: t-shirt sizes (small ... 2xlarge), smoke, mixed
├── docs/test-bench-design.md  design of the whole test bench
├── scripts/
│   ├── init-tfvars.sh         creates common.tfvars + every stack's terraform.tfvars
│   └── cache/                 read benchmark (planned; becomes the bench's Run module)
├── common.tfvars.example      settings shared by every stack
└── tf.sh                      wrapper: ./tf.sh <stack> <command>
```

A **module** is a building block ("how to build one FSx for ONTAP"). A **stack** is something you
deploy, with its own state, that calls modules ("build the Origin, and the Cache if switched on").
Stacks read the outputs of earlier stacks from their local state files.

## Creation order

Stacks and modules are numbered in the order they are created. A number only depends on lower
numbers, so deploy from `01` upwards and destroy from the highest number down. The exception is
`00-bench-store`: it holds results, is applied once and is left in place when a lab is destroyed.

```
stacks:   01-landing-zone ──► 02-fsxn ──► 03-ec2 ──► 04-flexcache ──► 05-bench (optional)
          00-bench-store (once, stays between labs) ── package bucket ─────────► read by 05-bench

modules:  01-network-origin ──┐                                 ┌──► 05-fsxn-origin ──┐
                              ├──► 03-peering ──► 04-managed-ad ─┤                     ├──► 07-ec2-client ──► 08-ontap-flexcache
          02-network-cache  ──┘                    (smb only)    └──► 06-fsxn-cache  ──┘                  └──► 09-bench-deploy ──► 11-bench-telemetry
          10-bench-store (stack 00) ─────────────────────────────── package bucket per region ───────────────────────────────────────┤
          05/06-fsxn ──► 12-bench-results-volume (vol_bench) ────────────────────────────────────────────────────────────────────────┘
```

| # | Stack | Reads from | Calls modules |
|---|---|---|---|
| 01 | `01-landing-zone` | – | `01-network-origin`, `02-network-cache`, `03-vpc-peering`, `04-managed-ad` (SMB) |
| 02 | `02-fsxn` | 01: VPCs, subnets, CIDRs, Managed AD (SMB) | `05-fsxn-origin`, `06-fsxn-cache` |
| 03 | `03-ec2` | 01: subnets, AD Admin secret (SMB) · 02: SVM NFS IPs / SMB names, junction paths | `07-ec2-client` |
| 04 | `04-flexcache` | 01: origin VPC · 02: management/intercluster IPs, SVMs, fsxadmin secret · 03: origin client | `08-ontap-flexcache` |
| 00 | `00-bench-store` (optional, once) | – | `10-bench-store` |
| 05 | `05-bench` (optional) | 03: Linux clients, regions, roles · telemetry: 00: package buckets, 01: VPCs (CloudWatch endpoints), 02: file systems, NFS IPs | `09-bench-deploy`, `12-bench-results-volume`, `13-bench-cloudwatch`, `14-bench-dashboard`, `11-bench-telemetry` |

| # | Module | Side | Needs |
|---|---|---|---|
| 01 | `01-network-origin` | Origin | – |
| 02 | `02-network-cache` | Cache | – (its CIDR must not overlap 01) |
| 03 | `03-vpc-peering` | both | 01 + 02: VPC IDs, route tables, CIDRs |
| 04 | `04-managed-ad` | Origin (SMB only) | 01: two subnets in different AZs · 03: the cache side reaches it |
| 05 | `05-fsxn-origin` | Origin | 01: VPC and subnet · 03: reachability · 04: domain (SMB) |
| 06 | `06-fsxn-cache` | Cache | 02: VPC and subnet · 03 · the Origin it caches (05) · 04: domain (SMB) |
| 07 | `07-ec2-client` | both | 01/02: the FSx for ONTAP subnet · 05/06: SVM NFS IP or SMB name |
| 08 | `08-ontap-flexcache` | both | 05 + 06: management/intercluster IPs, SVMs, origin volume · 07: the origin client runs it |
| 09 | `09-bench-deploy` | both | 07: Linux clients with SSM |
| 10 | `10-bench-store` | per region | – (one package bucket) |
| 11 | `11-bench-telemetry` | both | 07: clients and roles · 09: `/opt/bench` · 10: the package bucket of each client's region · 12: the results volume |
| 12 | `12-bench-results-volume` | origin (or cache) | 05/06: the file system and its SVM |
| 13 | `13-bench-cloudwatch` | both | 01: the client's VPC and subnet · 07: the client role |
| 14 | `14-bench-dashboard` | origin region | 05/06: file system IDs · 07: instance IDs · 12: the results volume ID |

The cache client's `/mnt/fsxn/vol_cache` (or `X:` for SMB) is configured in step 3 but only
appears once step 4 has created the FlexCache volume (the client retries every minute).

## How FlexCache is configured (stack 04)

The AWS FSx API has no cluster peering or FlexCache calls; they exist only in the ONTAP REST API on
each file system's **management IP**, which is private. So nothing has to reach those IPs from the
operator machine: the **origin EC2 client** does the work.

1. `terraform apply` creates a **Secrets Manager endpoint** in the origin VPC and lets the origin
   client's role read the fsxadmin secret.
2. It then runs `modules/08-ontap-flexcache/files/ssm-run.sh` on the operator machine, which sends the script
   to the origin client with **SSM Run Command** and waits for it: `files/flexcache.py` on Linux
   (NFS), `files/flexcache.ps1` on Windows (SMB). Both do the same steps.
3. On the client, the script reads the fsxadmin password from Secrets Manager (it is never part of
   the SSM command) and calls the ONTAP REST API on the Origin management IP (same VPC) and the
   Cache management IP (over the peering):
   - **cluster peer** Origin ⇄ Cache over the intercluster IPs, with a one-time passphrase
     generated on the client;
   - **SVM peer** `svm-cache` ⇄ `svm-origin` with the `flexcache` application, accepted on the
     Origin;
   - **FlexCache volume** `vol_cache` on `svm-cache` (500 GiB, `aggr1`), origin `vol_origin`,
     mounted at `/vol_cache`;
   - **SMB only:** share `origin` on `svm-origin` (→ `/vol_origin`) and share `cache` on
     `svm-cache` (→ `/vol_cache`), names set by `share_names`, with SMB encryption required.
4. `terraform destroy` runs the same script with `delete`: SMB shares, FlexCache (unmount, offline,
   delete), SVM peer, cluster peer.

Every step checks what already exists, so re-running is safe. Changing a FlexCache setting
(name, size, path, aggregates) deletes and recreates the FlexCache setup. The origin client needs
SSM (`enable_ssm = true` in `03-ec2`, the default); stack 04 stops with a clear message otherwise.

## Test bench (stack 05)

The test bench ([design](docs/test-bench-design.md)) lives in `bench/` and `profiles/`. The clients
have no internet and can't clone this repository, so stack 05 copies those folders to them over
SSM, the same way stack 04 sends the FlexCache script. It is optional and works only with
`protocol = "nfs"` (Linux clients).

```bash
./tf.sh 05-bench init
./tf.sh 05-bench plan
./tf.sh 05-bench apply-plan
```

On each client this:

- unpacks the bench into `/opt/bench`, with `/opt/bench/VERSION.json` recording the Git commit,
  branch, whether there were uncommitted changes, and a hash of the files;
- installs the `bench-dataset`, `bench-datasets-nfs` and `bench-results-sync` commands for every user;
- prints checks (Python version, PyYAML, mounts and free space) and runs the bench's tests.

**Updating:** change the code on the operator machine, then `plan` and `apply-plan` again. Only a change to the
files (or to the stack's settings) sends anything; otherwise the plan shows no changes. What is
deployed is the working copy, committed or not, so check `uncommitted_changes` in the output.

### Telemetry (OpenTelemetry Collector)

With `telemetry = true` (the default; set it in `stacks/05-bench/terraform.tfvars`) stack 05 also
installs on each client:

- the **OpenTelemetry Collector** (`otelcol-contrib`, pinned version, checked against its published
  SHA-256), collecting **host metrics** every 5 s: CPU, memory, load, disk, network, paging;
- **bench-probe**, feeding the Collector what it can't see itself: **NFS** operations per second,
  round-trip and execute time per NFS operation (from `/proc/self/mountstats`), the **EC2 network
  limit** counters (ENA `*_allowance_exceeded`) and **ping** times to both file systems' NFS IPs.

Everything goes to the **results volume** `vol_bench`: a new FSx for ONTAP volume on the origin
file system (`results_volume.side = "cache"` puts it on the cache), mounted on both clients at
`/mnt/fsxn/vol_bench` (the cache client mounts it across the peering). **No results go to S3.**

```
/mnt/fsxn/vol_bench/
  telemetry/<lab>/<side>/<instance-id>/metrics*.json   Collector output, OTLP JSON, files of 50 MiB
  datasets/<dataset-id>/                              dataset records, shared by every user and both clients
  logs/                                               bench-datasets-nfs --background logs
  labs/<lab>/lab.json                                 regions, file systems, clients, results volume
```

**Nothing is written to `vol_bench` while a test runs**: extra NFS writes would load the file
systems being measured. During a test, the Collector, the dataset records and the logs all write to
the client's **local** staging folder, `/var/lib/bench/staging`. They are copied to `vol_bench` only
**after** the test:

- at the end of each `bench-dataset create`, `modify`, `verify` or `delete`, and once at the end of
  a whole `bench-datasets-nfs` batch (after the last size);
- by hand, at any time: `bench-results-sync`;
- one last time when stack 05 is destroyed: the Collector is stopped, everything staged is copied,
  and only then is `vol_bench` unmounted, deleted and backed up. If that copy fails, the destroy
  stops, so nothing is lost.

Dataset records then live on `vol_bench`; a later command (from either client) reads them from there
before it starts. The Collector runs all the time while the lab is up, so any dataset or test can
later be lined up with it by time. Its local files are capped at 2 GiB (`local_buffer_mib`): if no
copy happens for days, the oldest local telemetry is dropped rather than filling the client's disk.

**When the lab goes, the results stay:** deleting `vol_bench` (destroying stack 05) makes FSx take a
**final backup** of it, which outlives the file system. `./tf.sh 05-bench output` shows the command
that lists the backups. Restoring one into a new lab is not automated yet.

**ONTAP counters (`bench-ontap`).** With `ontap_metrics = true` (the default) and stack 04 applied,
the origin client also polls **both** clusters' ONTAP REST API every 15 s with the **fsxadmin**
credentials (read from Secrets Manager through the endpoint of stack 04): per watched volume
(`vol_origin`, `vol_cache`, `vol_bench`) the cumulative `statistics` counters, turned into IOPS,
throughput and average latency per operation type, NFS operations and latency per NFS operation,
and for the FlexCache the blocks requested by clients and fetched from the origin (the cache
miss %). It also measures the **latency between the two file systems** with ONTAP's own tools,
in both directions: `network ping` from each cluster's intercluster LIFs to the other cluster's
intercluster IPs, and `cluster peer ping` (both through the REST CLI passthrough; a method FSx
refuses is logged once in `journalctl -u bench-ontap` and switched off). As a fallback it pings
both clusters' intercluster IPs from the origin client. Like the rest, the data is staged locally, copied to
`vol_bench` and pushed to the dashboard after each test. Without stack 04 it is simply off.

The clients have no internet, so the Collector package reaches them through a small **package
bucket** (S3, `vendor/` only; the clients may only read from it), created once per account:

```bash
./tf.sh 00-bench-store init
./tf.sh 00-bench-store plan
./tf.sh 00-bench-store apply-plan
```

Then `plan` and `apply-plan` stack 05 as above. The apply creates `vol_bench`, downloads the
Collector package once on the operator machine (it needs internet; the clients don't), copies it
into the package bucket(s), mounts `vol_bench` and installs the Collector on each client, validates
its config, starts both services and waits until telemetry is being staged locally. Without
stack 00, a plan with `telemetry = true` stops with "Unable to find remote state"; apply stack 00 or
set `telemetry = false`. On a client, `systemctl status otelcol-contrib bench-probe` shows both
services.

The FSx for ONTAP and EC2 metrics in CloudWatch, and the consolidated report that puts everything
on one time axis, come next.

Stack 05 only **installs the tools**. It creates no datasets, and destroying it doesn't delete any.

### Creating the datasets (users, by hand)

Datasets are created **manually by the users**, on the client that has the volume mounted:
normally the origin client, writing to `vol_origin`. Each user runs the steps below when they need
a dataset; nothing runs on a schedule or as part of an apply.

1. **Log in to the origin client.** `./tf.sh 05-bench output` (or `./tf.sh 03-ec2 output`) prints
   the command, e.g. `aws ssm start-session --target <origin-client-id> --region <origin_region>`.
2. **Check the volume and the space.**

   ```bash
   df -h /mnt/fsxn/vol_origin
   bench-dataset list                                 # datasets already recorded by you
   ```

3. **Smoke test** (200 files, a few MB) to check that the tools work:

   ```bash
   bench-dataset create --target /mnt/fsxn/vol_origin --spec smoke
   bench-dataset verify <dataset-id> --side origin
   ```

4. **Plan the t-shirt sizes** you need. `--dry-run` shows the sizes and checks the free space for
   all of them together; with the lab defaults all six (910 GiB) don't fit in the 800 GiB
   `vol_origin`.

   | Size | Files of | Total |
   |---|---|---|
   | `small` | 64 KiB | 10 GiB |
   | `2xsmall` | 1 MiB | 50 GiB |
   | `medium` | 5 MiB | 100 GiB |
   | `2xmedium` | 10 MiB | 200 GiB |
   | `large` | 50 MiB | 250 GiB |
   | `2xlarge` | 1 GiB | 300 GiB |

   ```bash
   bench-datasets-nfs --dry-run small 2xsmall medium
   ```

5. **Optionally a 1 % trial run**, then **the real run in the background** (the larger sizes take
   from minutes to hours, longer than an SSM session should stay open):

   ```bash
   bench-datasets-nfs --scale 0.01 small medium
   bench-datasets-nfs --background small 2xsmall medium
   tail -f /var/lib/bench/staging/logs/datasets-nfs-<user>-<time>.log   # the exact path is printed
   ```

6. **Check the result**, and delete datasets you no longer need to free the space:

   ```bash
   bench-dataset list
   bench-dataset verify <dataset-id> --side origin
   bench-dataset delete <dataset-id> --yes
   ```

7. **Measure the reads**, on both sides. On the origin client (baseline), then on the cache client
   (through FlexCache), the same command:

   ```bash
   bench-dataset read <dataset-id> --side origin     # reads /mnt/fsxn/vol_origin
   bench-dataset read <dataset-id> --side cache      # reads /mnt/fsxn/vol_cache (FlexCache)
   ```

   Every file is opened and read to the end, and each file's **open**, **first byte**, **whole
   file** and **close** are timed. Each pass reports the total, e.g. "10.0 GiB in 163840 files in
   312.4 s, 34.4 MB/s", with p50 / p99 / max for the four steps. Two passes by default, with the
   client's page cache dropped before each: through FlexCache, pass 1 is **cold** (if the cache
   hasn't seen these files yet) and pass 2 **warm**. `--mode first` reads only the first block,
   `--mode open` only opens and closes (the metadata cost of opening that many GB of files);
   `--files N` or `--percent P` read a sample. The results go to `reads/` in the dataset's records
   and to the dashboard (read throughput and latency per pass).

Each dataset gets an id (`ds-<size>-<utc time>`). Its files go to
`/mnt/fsxn/vol_origin/<dataset-id>/`, its records (spec, manifest, per-file timings) to
`/mnt/fsxn/vol_bench/datasets/<dataset-id>/` on the results volume. Keep in mind:

- **Records are shared.** Every user on both clients sees and can update them, so `list`,
  `verify`, `modify` and `delete` work for anyone, from either client.
- **During the command they are only local** (`/var/lib/bench/staging/datasets/`), and copied to
  `vol_bench` when it ends; `bench-dataset list` shows `[staged]` for any not copied yet (e.g. if the
  copy failed: run `bench-results-sync`).
- **Without the results volume** (`telemetry = false`), records go to `~/bench-results/datasets/`
  of the user who created them, on that client only, and destroying `03-ec2` deletes them.
- The dataset files themselves stay on `vol_origin` until `02-fsxn` is destroyed; the records on
  `vol_bench` go into its final backup.
- Changing data from the cache side (`bench-dataset modify --side cache --target /mnt/fsxn/vol_cache`)
  is also done by hand, on the cache client, with the records of the original dataset.

All commands, sizes and options: [bench/dataset/README.md](bench/dataset/README.md).

### Consulting the results

**The consolidated view: the CloudWatch dashboard** (`cloudwatch = true`, the default). One page per
lab, `<creator>-<project>-bench`, origin on the left and cache on the right:

- the bench's own metrics: dataset write throughput, open/write/close latency (p50, p99), dataset
  reads per pass (MB/s, open, first byte, whole file and close latency), client
  CPU, memory and network, NFS round-trip and operations per NFS operation, EC2 network-limit
  counters, ping to both file systems;
- ONTAP's own counters for both clusters (`ontap_metrics = true`, needs stack 04): volume latency,
  IOPS and throughput per operation type, NFS latency per NFS operation, **FlexCache misses**
  (miss %, blocks requested and fetched from the origin) and the **latency between the FSx file
  systems**, shown in both columns next to the read results;
- next to AWS's own: FSx for ONTAP throughput and IOPS per volume, read/write latency, CPU and
  network utilization, and the clients' EC2 CPU.

```bash
./tf.sh 05-bench output dashboard      # the dashboard URL (AWS console, normal IAM sign-in)
```

The bench's metrics are pushed **after each test**, by `bench-results-sync`, at the same moment the
results are copied to `vol_bench`: a test shows up on the dashboard when it ends, and nothing extra
happens during it. They are one-minute statistics, kept by CloudWatch for 15 days at that
resolution (5-minute for 63 days, hourly for 15 months). Details: `modules/14-bench-dashboard`.

**The full record: the results volume**, readable from **either client** (log in with the command
from `./tf.sh 05-bench output`):

```
/mnt/fsxn/vol_bench/
  datasets/<dataset-id>/dataset.json        summary: spec, mount/NFS options, timings, throughput, latency percentiles
  datasets/<dataset-id>/manifest-g<N>.csv.gz every file: path, size, checksum
  datasets/<dataset-id>/ops-g<N>.csv.gz      one row per file: open, write, fsync, close in microseconds
  telemetry/<lab>/<side>/<instance-id>/metrics*.json   Collector output, one OTLP JSON batch per line
  logs/                                      bench-datasets-nfs --background logs
  labs/<lab>/lab.json                        regions, file systems, clients, results volume
```

What works today:

- **Which datasets exist, and are they intact:**

  ```bash
  bench-dataset list
  bench-dataset verify <dataset-id> --side origin
  ```

- **All datasets side by side** (throughput, files/s, open and close latency in microseconds):

  ```bash
  python3 - <<'PY'
  import glob, json
  print(f"{'dataset':32}{'files':>8}{'GiB':>8}{'MB/s':>8}{'files/s':>9}{'open p50':>10}{'open p99':>10}{'close p99':>11}")
  for p in sorted(glob.glob("/mnt/fsxn/vol_bench/datasets/*/dataset.json")):
      m = json.load(open(p)); g = m["generations"][0]; lat = g["latency_us"].get("create", {})
      us = lambda f, q: lat.get(f, {}).get(q, "-")
      print(f"{m['id']:32}{g['files']:>8}{g['bytes']/2**30:>8.1f}{g['throughput_bytes_per_s']/1e6:>8.1f}"
            f"{g['files_per_s']:>9.1f}{us('open_us','p50'):>10}{us('open_us','p99'):>10}{us('close_us','p99'):>11}")
  PY
  ```

- **What the Collector recorded** (metric names and how many data points):

  ```bash
  cat /mnt/fsxn/vol_bench/telemetry/*/*/*/metrics*.json | python3 -c 'import json,sys,collections
  c = collections.Counter()
  for line in sys.stdin:
      for rm in json.loads(line)["resourceMetrics"]:
          for sm in rm["scopeMetrics"]:
              for m in sm["metrics"]:
                  c[m["name"]] += len(next(iter(v for k, v in m.items() if k in ("gauge", "sum", "histogram"))).get("dataPoints", []))
  for name, n in sorted(c.items()): print(f"{n:>8}  {name}")'
  ```

- **FSx for ONTAP and EC2 metrics:** on the dashboard, or in CloudWatch → Metrics → `AWS/FSx` and
  `AWS/EC2` for the dataset's time window (`started` / `finished` in its `dataset.json`). They are
  not copied to `vol_bench`, and CloudWatch keeps 1-minute data for 15 days only.

**After the lab is destroyed**, the results are in the final backup of `vol_bench`. To look at them
again, a lab (at least `02-fsxn` and one client) must be running; restore the backup as a new volume
and mount it on a client:

```bash
aws fsx describe-backups --region <origin_region> --query "Backups[?Tags[?Key=='Purpose' && Value=='bench-results']].[BackupId,CreationTime,Volume.Name]" --output table
aws fsx create-volume-from-backup --region <origin_region> --backup-id <backup-id> --name vol_bench_restored \
  --ontap-configuration "StorageVirtualMachineId=<svm-id>,JunctionPath=/vol_bench_restored,SizeInMegabytes=102400"
```

Then on a client: `sudo mkdir -p /mnt/fsxn/vol_bench_restored && sudo mount <svm-nfs-ip>:/vol_bench_restored
/mnt/fsxn/vol_bench_restored`. Delete the restored volume afterwards (`aws fsx delete-volume`);
it is not managed by Terraform.

**Planned: `bench-report`.** A self-contained HTML page per dataset or test, from `vol_bench`, for
reviews beyond CloudWatch's retention or after the lab is gone (with a restored backup).

## Settings

Module variables are never set directly: each stack fills them in. You only edit these files
(all git-ignored). `./scripts/init-tfvars.sh` creates all of them from the `.example` next to them:

| File | Main settings |
|---|---|
| `common.tfvars` (every stack) | `project`, `creator`, `origin_region`, `cache_region`, `deploy_origin`, `deploy_cache`, `protocol`, `origin_azs`, `cache_azs` |
| `stacks/01-landing-zone/terraform.tfvars` | VPC CIDRs, subnet CIDR overrides, `origin_nat_gateway` / `cache_nat_gateway` (default `false`); SMB: `ad_domain_name` (`flexcache.lab`), `ad_short_name` (`FLEXCACHE`), `ad_edition` (`Standard`), `ad_az`, `ad_subnet_cidr` |
| `stacks/02-fsxn/terraform.tfvars` | `origin_fsxn` / `cache_fsxn` (default SINGLE_AZ_1, 128 MB/s, 1024 GiB), `origin_volume` (default `vol_origin`, FlexGroup, 800 GiB, storage efficiency on); SMB: `svm_netbios_names` (`origin`, `cache`) |
| `stacks/03-ec2/terraform.tfvars` | `origin_ec2` / `cache_ec2`, `instance_type` (`t3.small` Linux, `t3.medium` Windows), `enable_eice` / `enable_ssm`, `nfs_options`, `cache_mounts_origin`; SMB: `domain_join` (`true`), `smb_drives` (`O`, `X`) |
| `stacks/00-bench-store/terraform.tfvars` | `noncurrent_version_days` (30): the package bucket |
| `stacks/05-bench/terraform.tfvars` | `bench_clients` (`origin`, `cache`), `install_packages` (none; e.g. `python3-pyyaml`), `run_tests` (`true`), `telemetry` (`true`), `cloudwatch` (`true`), `ontap_metrics` (`true`), `results_volume` (`side = "origin"`, `name = "vol_bench"`, `size_gib = 100`), `telemetry_interval_s` (5), `ping_interval_s` (10), `collector_version` (`0.165.0`), `collector_architectures` (`amd64`) |
| `stacks/04-flexcache/terraform.tfvars` | `flexcache_name` (`vol_cache`), `flexcache_size_gib` (500), `flexcache_junction_path`, `cache_aggregates`, `create_secrets_endpoint`; SMB: `share_names` (`origin`, `cache`) |

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
| EC2 client (also `origin_ec2` / `cache_ec2`) | `03-ec2` | origin client | cache client | both |
| FlexCache (needs the origin client) | `04-flexcache` | | | ✅ |

- After changing a switch, apply the stacks in order (`01`, `02`, `03`, then `04`): each side needs
  its network first. Stacks 02, 03 and 04 stop with a clear error if something is missing.
- Switching a side **on** adds it without touching the other side. Switching it **off** destroys
  that side, so remove what depends on it first (`04-flexcache`, `03-ec2`, then `02-fsxn`, then
  `01-landing-zone`).
- Both switches `false` is rejected.
- Keep the switches in `common.tfvars` rather than passing `-var`, so a later plain `apply` doesn't
  switch a side back off.

## NFS or SMB

```hcl
# common.tfvars
protocol = "nfs" # default; "smb" for Windows and SMB shares
```

| What | `nfs` (default) | `smb` |
|---|---|---|
| Directory (`01-landing-zone`) | none | AWS Managed Microsoft AD `flexcache.lab` in the origin VPC, on the first origin subnet plus a second one in another AZ (`x.x.200.0/24`); Admin password in the secret `<creator>-<project>/ad-admin` |
| SVMs (`02-fsxn`) | UNIX security | joined to the domain as `origin` / `cache` (NetBIOS), NTFS security, TCP 445 open |
| Clients (`03-ec2`) | Amazon Linux 2023, NFS mounts under `/mnt/fsxn` | Windows Server 2022, computer names `origin-client` / `cache-client`, joined to the domain |
| FlexCache (`04-flexcache`) | `flexcache.py` | `flexcache.ps1`, plus the shares |
| Origin client | `/mnt/fsxn/vol_origin` | share `origin` (→ `vol_origin`) on `O:` |
| Cache client | `/mnt/fsxn/vol_cache` | share `cache` (→ the FlexCache `vol_cache`) on `X:` |

- **Pick the protocol before the first apply.** Switching later rebuilds the SVMs, the origin volume
  and the clients: destroy `04`, `03` and `02` first, then apply all four stacks again.
- **SMB needs the origin side** (`deploy_origin = true`), because the directory lives in the origin
  VPC. The cache SVM and cache client reach it over the peering; with a cross-region cache the
  Admin secret is replicated to `cache_region`.
- **The Windows clients join the domain** (`domain_join = true` in `03-ec2`, the default) into
  `OU=Computers,OU=FLEXCACHE,...`. A scheduled task (`fsxn-map`) reads the Admin secret, joins after
  the rename and restarts, then maps the shares for every user with the domain's `Admin` account.
  The local `Administrator` keeps its own random password (it only gets the AD Admin password
  with `domain_join = false`). Every user of a client sees the shares with the `Admin` account's
  rights: fine for a lab, not for production.
- **Hardening:** `C:\fsxn` (the task scripts, `flexcache.ps1` from stack 04 and the log) is
  readable and writable by SYSTEM and Administrators only. The shares require SMB encryption.
  `flexcache.ps1` skips the certificate check only for the two ONTAP management IPs (FSx uses a
  self-signed certificate); Secrets Manager calls are validated as usual. The clients may read the
  AD Admin secret only in their own account and region.
- **Names in the domain:** SVMs `svm-origin` / `svm-cache` with the SMB (NetBIOS) names `origin` /
  `cache`, shares `origin` / `cache`, Windows clients `origin-client` / `cache-client`. The SVM and
  client names must differ: in the same domain they would share one computer account.
- **Security style follows the protocol:** `NTFS` with `smb`, `UNIX` with `nfs`, on the SVM root
  and `vol_origin`; the FlexCache takes the origin's.
- **Only the domain's names go to the domain controllers.** An NRPT rule sends `*.flexcache.lab`
  to the AD DNS and everything else to the VPC DNS, so the VPC endpoints keep working.
- **Shares are mapped by the SVM's name** (`\\origin.flexcache.lab\origin`, Kerberos), or by
  its IP while that name doesn't resolve. With `domain_join = false` the clients stay in a
  workgroup and map by IP (NTLM).
- **Each Windows client gets a Secrets Manager endpoint** in its VPC, so stack 04 doesn't create a
  second one in the origin VPC.

## Operator machine

The one machine you run Terraform from: a workstation, a jump host or a CI runner, Linux or macOS.
It holds the Terraform state, so use the same machine for the whole life of a lab.

- **Tools:** Terraform ≥ 1.10 (or OpenTofu, `TF_BIN=tofu`), AWS CLI v2, `bash`, `gzip`, `tar`,
  `base64` and `git`. For SSM logins also the Session Manager plugin. Installation:
  [step 1](#1-get-the-code-and-the-tools).
- **AWS credentials:** `export AWS_PROFILE=<profile>`. The profile must be able to create VPCs,
  peering, FSx for ONTAP, EC2 instances and endpoints, IAM roles and policies and Secrets Manager
  secrets, and to use SSM Run Command (`ssm:SendCommand`, `ssm:GetCommandInvocation`). In a sandbox
  account `AdministratorAccess` is simplest (`PowerUserAccess` can't create the IAM role).
- **Every stack only calls AWS APIs**, so all of them work from anywhere with internet. Nothing
  connects from the operator machine into the VPCs except your logins through the endpoints.

## The EC2 clients

With `protocol = "smb"` the clients are Windows Server 2022 instances (`t3.medium` by default) that
map the SMB shares instead; see [NFS or SMB](#nfs-or-smb). The rest of this section is the NFS
default.

Each client is an Amazon Linux 2023 instance in the **same private subnet as its side's FSx for
ONTAP**, with the Linux hostname `origin-client` or `cache-client`. At boot it adds the NFS mounts to `/etc/fstab`, and a systemd timer retries `mount -a` every
minute, so a volume that doesn't exist yet is mounted within a minute of being created. Each mounted
volume's top directory is set to `1777`, so `ssm-user` (SSM) and `ec2-user` (Instance Connect) can
both write to it:

| Client | Mounts |
|---|---|
| origin | `/mnt/fsxn/vol_origin` ← origin SVM `:/vol_origin` |
| cache | `/mnt/fsxn/vol_cache` ← cache SVM `:/vol_cache` (FlexCache). Optional (`cache_mounts_origin = true`): `/mnt/fsxn/vol_origin` ← origin SVM over the peering, as a no-cache baseline |

Default NFS options: `vers=3,nconnect=8,hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576`
(change with `nfs_options`). The origin client also runs the FlexCache configuration (stack 04).

Log in from the operator machine (the exact commands are in `./tf.sh 03-ec2 output`):

```bash
aws ec2-instance-connect ssh --instance-id <id> --connection-type eice   # EC2 Instance Connect Endpoint
aws ssm start-session --target <id>                                      # SSM Session Manager
```

Both endpoints are created per VPC by `07-ec2-client`. The Instance Connect Endpoint may only SSH to
the client (RDP for Windows); the SSM interface endpoints only accept HTTPS from it. `t3.small` is enough to check the
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
| Managed AD (SMB) | `pedro-flexcache-perf-ad`, secret `pedro-flexcache-perf/ad-admin`, subnet `...-origin-directory-eu-west-1b` |
| EC2 instances (shorter on purpose: `<creator>-<side>-client`) | `pedro-origin-client`, `pedro-cache-client` |
| EC2 supporting resources | `pedro-flexcache-perf-origin-client-eice`, `...-origin-client-ssm-endpoint`, `...-cache-client-sg` |
| FlexCache (stack 04) | `pedro-flexcache-perf-flexcache-secretsmanager-endpoint`, policy `...-flexcache-read-fsxadmin` |

`creator` may only contain lowercase letters, digits and hyphens, because it is part of every name.

- **Also tagged:** each VPC's default security group, main route table and network ACL (AWS creates
  them untagged; the network modules adopt them), and the clients' root EBS volumes.
- **Not taggable:** routes and route-table associations, IAM inline policies, and the ONTAP objects
  (cluster peer, SVM peer, FlexCache volume).

## State and the fsxadmin password

Each stack writes `stacks/<stack>/terraform.tfstate` on the operator machine (git-ignored). It contains the
generated fsxadmin password, so never commit it.

- **One fsxadmin password** for both FSx for ONTAP: `02-fsxn` generates it and stores it in the
  Secrets Manager secret `<creator>-<project>/fsxadmin` in the origin region. To read it:
  `aws secretsmanager get-secret-value --secret-id <creator>-<project>/fsxadmin --region <origin_region>`
- **SMB: one AD Admin password.** `01-landing-zone` generates it for the Managed AD and stores it in
  `<creator>-<project>/ad-admin` (origin region, replicated to a different `cache_region`). It is
  also in the stack 01 state file.
- **Keep the state files.** Destroy the lab before you delete the clone, and back the `*.tfstate`
  files up with your usual backup. Without them Terraform no longer knows what it created.
- Moving to S3 later is a one-file change per stack (`backend.tf`) plus `terraform init -migrate-state`.

## Destroy

Reverse order, highest number first. Each asks for `yes`:

```bash
./tf.sh 05-bench destroy            # only if deployed: removes the bench and the collector from the clients
./tf.sh 04-flexcache destroy        # runs on the origin client: FlexCache, SVM peer, cluster peer
./tf.sh 03-ec2 destroy              # destroy 04 first: it needs the origin client
./tf.sh 02-fsxn destroy             # deletes both FSx for ONTAP and the fsxadmin secret
./tf.sh 01-landing-zone destroy     # SMB: deleting the Managed AD takes 20-45 min
```

Destroying `05-bench` first copies everything still staged on the clients to `vol_bench`, then
deletes `vol_bench`, and FSx takes a **final backup** of it; that backup outlives `02-fsxn`. So
always destroy `05-bench` before `02-fsxn` and `03-ec2`.

`00-bench-store` is left in place between labs: it only holds the Collector package. Terraform
won't delete a bucket that isn't empty; `aws s3 rm --recursive s3://<bucket>` first if you want it
gone.

## Network notes

- **Availability Zones** are letters added to the region in `common.tfvars`: `origin_azs = ["a"]`
  and `cache_azs = ["a"]` (default `eu-west-1a`). Each AZ gets one private /24 (`x.x.1.0`,
  `x.x.2.0`, ...). Single-AZ FSx for ONTAP and the EC2 clients use the first AZ; Multi-AZ needs
  two, e.g. `["a", "b"]`.
- **CIDRs** must not overlap (defaults: origin `10.10.0.0/16`, cache `10.20.0.0/16`).
- **No NAT gateway is needed** (off by default): FSx for ONTAP never starts internet traffic, the
  clients reach SSM and Secrets Manager through interface endpoints and Amazon Linux packages
  through the free S3 gateway endpoint. With NAT on, the first AZ also gets a public /24
  (`x.x.101.0`).
- **Security groups** on both FSx for ONTAP allow, from both VPCs: NFS (TCP/UDP 111, 635, 2049,
  4045-4046, UDP 4049), ONTAP management (TCP 443, 22), intercluster (TCP 11104-11105) and ICMP.
  That is what lets the origin client reach the Cache management IP over the peering.
- **SMB** (`protocol = "smb"`) also opens TCP 445 on both FSx for ONTAP, and the Managed AD's own
  security group gets the AD ports (DNS, Kerberos, LDAP, SMB, RPC) from the cache VPC.
- **Cluster peering and FlexCache** use the intercluster IPs and run over the VPC peering.
- **Single-AZ is the default** because its management and NFS endpoints are normal VPC IPs that
  work across peering. Multi-AZ endpoints use floating IPs that don't route over peering (they
  would need Transit Gateway).

## Costs

- **FSx for ONTAP** is billed per hour for throughput capacity and SSD: destroy `02-fsxn` between
  test campaigns.
- **EC2 clients:** `t3.small` is about USD 0.02/h each.
- **SSM endpoints:** about USD 0.03/h per VPC for the three of them (`enable_ssm = false` to skip;
  the origin client needs them for stack 04).
- **Secrets Manager endpoint** (stack 04, origin VPC): about USD 0.01/h.
- **EC2 Instance Connect Endpoint:** free.
- **Test bench:** the results volume `vol_bench` (100 GiB SSD by default) is billed as FSx for ONTAP
  SSD storage on the origin file system; its **final backup** as FSx backup storage, until you
  delete it. The package bucket only holds the 118 MB Collector package per region.
  - **CloudWatch** (`cloudwatch = true`), only while the lab (stack 05) exists:
    - one `monitoring` interface endpoint per client VPC, about USD 0.01/h each, removed with stack 05;
    - the bench's custom metrics: AWS bills a metric only for the **hours in which data is sent**
      for it (about USD 0.30 per metric per month, prorated by the hour). The bench sends once at
      the end of each test, so each push costs roughly USD 0.30 / 730 per metric: with a few hundred
      metrics, a few tens of cents per test, and nothing between tests or once the lab is gone;
    - the dashboard (the first three in an account are free, then about USD 3 per month each),
      removed with stack 05. Stored metric data costs nothing.
    Set `cloudwatch = false` to skip it.
- **SMB only:**
  - **AWS Managed Microsoft AD** is billed per domain controller hour, and there are always two.
    An older AWS estimate puts Standard Edition at about USD 0.14/h; check the
    [pricing page](https://aws.amazon.com/directoryservice/pricing/) for your region.
  - **Windows clients** include the Windows license in the hourly price, so they cost more than the
    Linux ones.
  - **Secrets Manager endpoint** per Windows client VPC: about USD 0.01/h each.
