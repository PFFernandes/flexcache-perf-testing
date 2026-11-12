# Test bench framework – design

Status: **draft v13 for review**. Built so far: sections marked "(built)" (§2.7, §2.8, §4.3, §4.5); the rest is design.

The Terraform stacks build the lab (Origin, Cache, two EC2 instances, FlexCache). The test bench is
the layer on top: it fills the volumes with datasets, runs read/write and file open/close tests from
either side, captures everything that happens during a test, keeps it in AWS after the lab is
destroyed, and lets us review it later on a dashboard.

| Version | Change |
|---|---|
| v2 | Tests driven inside AWS (Step Functions), run by the EC2 instances; per-file open/close latency (`bench-fileops`); results in S3 + Athena. |
| v3 | Decisions recorded (§0). **OpenTelemetry** as the telemetry pipeline, **NetApp Harvest** for ONTAP metrics, dashboard **without IAM Identity Center** (§7). Only the two existing EC2 instances; NFS v3 **and** v4.1; cross-region in scope from the start; review after the fact first, live view later. |
| v4 | After a design review: test questions first (§1.1); measurement-validity rules (§5.6); honest cold/warm definitions; run lock, pre-flight, cleanup, dry-run (§2.4); no S3 replication; read-only ONTAP user; review Grafana without a public IP; phases reordered so the first numbers come before the platform (§9). |
| v5 | The bench platform is an **optional last stack**, `05-bench`, built after stacks 01-04 (§2.5). It installs the bench onto the workers itself, so stacks 01-04 work unchanged without it. |
| v6 | The bench is organised as **four modules**: Dataset, Tooling, Run, Observe (§2.6). Results are saved in a store that is separate from Observe, so Observe can be deleted, recreated and attached to saved results later. |
| v7 | Built: module 1 (Dataset, `bench/dataset`) and delivery to the clients: `modules/09-bench-deploy` + `stacks/05-bench` (§2.7). Module numbers follow the repository today (`07-ec2-client`, `08-ontap-flexcache`), so the bench's Terraform modules start at 09. |
| v8 | **Datasets are manual**: users create, change, verify and delete them by hand on the clients (`bench-dataset`, `bench-datasets-nfs`). No state machine, Lambda or schedule touches datasets; the automation starts at the test runs (§2.6, §4). |
| v9 | Built: results store as **stack `00-bench-store`** (not inside stack 05) and telemetry: OpenTelemetry Collector + bench-probe on the clients, writing to S3 (§2.8). Collection is continuous while a lab is up; results are lined up by time. |
| v13 | **Read test on both sides** (`bench-dataset read --side origin|cache`): per file open, first byte, whole file and close; per pass the wall-clock time to read the dataset (XX GB in N files), MB/s, files/s; passes with the client cache dropped (pass 1 cold through FlexCache, pass 2 warm); `--mode first|open`. Stored as separate `reads/` files and pushed to the dashboard. Bundle delivery split into 40 KB SSM commands. |
| v12 | **Consolidated view: an Amazon CloudWatch dashboard** per lab (`modules/14-bench-dashboard`): the bench's metrics, pushed **after each test** by `bench-results-sync` (`bench/results/cloudwatch.py`, through a CloudWatch endpoint per client VPC, `modules/13-bench-cloudwatch`), next to the AWS/FSx and AWS/EC2 metrics. Amazon Managed Grafana was ruled out (no Identity Center); `vol_bench` stays the full-resolution record. |
| v11 | **Nothing is written to the results volume during a test.** Telemetry, dataset records and logs are staged on the client's local disk and copied to `vol_bench` after each command, by hand (`bench-results-sync`) and on destroy (§2.8). |
| v10 | **No results in S3.** Results go to an FSx for ONTAP **results volume** (`vol_bench`, origin by default) mounted on both clients, with a **final backup** when it is deleted. The S3 bucket of stack 00 only delivers the Collector package to the clients. Supersedes the S3 store of §6 and v9. |

## 0. Decisions so far

| Topic | Decision |
|---|---|
| Workers | Only the two EC2 instances the lab already deploys: `<creator>-origin-client` and `<creator>-cache-client`. |
| NFS versions | **Both** `vers=3` and `vers=4.1` are tested; NFS version is a test dimension. |
| FlexCache write-back | To investigate (FSx supports it since May 2025, ONTAP 9.15.1+ on origin and cache). Not a priority: lab option and tests come in a later phase. |
| Cross-region | **Planned.** Built into the platform from phase 1. |
| Datasets | **Manual.** Users log in to the client and run `bench-dataset` / `bench-datasets-nfs` themselves. Only the test runs are automated. Six t-shirt sizes are defined (§4.5). |
| Results storage | **An FSx for ONTAP results volume, `vol_bench`**, on the origin (or cache) file system, mounted on both clients. FSx takes a final backup when it is deleted; that backup is how results outlive a lab. No results in S3; S3 only delivers the Collector package (the clients have no internet). |
| Priority | **Review results after the fact** is the priority. Live indicators during a run: nice to have, later. |
| Identity Center | Not available → no Amazon Managed Grafana. Dashboard choice in §7, **to decide**. |
| Platform stack | **`05-bench`, applied after 01-04, only if wanted** (`deploy_bench = true`). The lab works without it. Its data survives a lab teardown (§2.5). |
| Home account / region | Assumption: the lab's AWS account, origin region. |

## 1. Goals and constraints

| # | Goal |
|---|---|
| G1 | **Datasets, created by hand by the users:** create random files on the origin volume from a file count, a file size (or size range) and a total capacity. Optionally write from the cache side: new files or modifications of existing ones. |
| G2 | **Performance tests** on the origin, the cache or both (one switch), run by the two EC2 instances: throughput, IOPS and latency (fio), and **file open / close latency on a cold and on a warm cache** (`bench-fileops`). Plus host CPU/memory/network, the latency between the two clusters (ONTAP cluster peer ping) and CloudWatch metrics. |
| G3 | **Dashboard in AWS** to review any stored run later: all sources on one time axis, events marked, runs compared. Works when the lab is destroyed. |
| G4 | **Everything kept in AWS:** configurations, test definitions, raw and processed results, so a new lab can repeat any old test. |
| G5 | **No operator machine in the loop:** a test is started from anywhere with AWS access (CLI, console, schedule) and runs to the end on its own. |

Constraints from the lab as it is today:

- The lab VPCs have **no internet**. The EC2 instances reach AWS only through endpoints: SSM,
  Secrets Manager (origin VPC) and the **S3 gateway endpoint** (both VPCs, **same region only**).
  Anything they install (OTel Collector, node_exporter, Harvest) is staged in S3 first.
- The ONTAP REST API (management IPs) is reachable **only from inside the VPCs**. The origin
  instance already reads the fsxadmin secret and reaches both clusters, also across regions over
  the peering (stack 04).
- The lab is destroyed between campaigns; the bench platform is **not**, so its idle cost must be
  close to zero (§11).
- CloudWatch keeps 1-minute data for 15 days only, so it is copied into the bench store at the end
  of every step.

### 1.1 Questions the bench must answer

The suites, the test matrix and the dashboards are derived from these questions, not the other way
round. Anything that answers none of them is not built. **Draft list, to confirm:**

| # | Question | Answered by |
|---|---|---|
| Q1 | How long does a file open (and close) take through the cache when it is **cold**, compared with **warm**, with the origin itself and with the origin across the peering without a cache? | `open-latency` |
| Q2 | How does that change with **NFS v3 vs v4.1**? | `open-latency --nfs v3,v4.1` |
| Q3 | How does it change with **file size** and **directory size**? | `open-latency` on a mixed dataset, split by size bucket |
| Q4 | What read throughput, IOPS and latency does a client get from the cache (cold, warm) vs the origin? | `cache-read` |
| Q5 | What does a **write from the cache side** cost compared with a write at the origin? | `cache-write` |
| Q6 | How much does **distance** (same-region vs cross-region, peer RTT) change Q1, Q4 and Q5? | same suites on two labs, compare |
| Q7 | What happens to cache clients when files **change at the origin**? | `open-latency` (invalidated step), `contention` |
| Q8 | What happens when the dataset is **larger than the FlexCache** (eviction)? | `cache-read` with an oversized dataset |
| Q9 | (later) What does **write-back** change for Q5? | `writeback` |

## 2. Architecture

Two layers with different lifetimes:

- **Bench platform** (stack `05-bench`, the optional last stack, home region; its data is persistent, §2.5): S3 store, Step
  Functions, a few Lambda functions, Glue/Athena tables, the review dashboard (§7). Serverless
  except the dashboard, which only runs while someone looks at it.
- **Lab** (stacks 01-04, per campaign): FSx for ONTAP, FlexCache and the two **workers** running
  `bench-agent` and an **OpenTelemetry Collector**.

```
                          BENCH PLATFORM (persistent, home region = origin region)
 ┌────────────────────────────────────────────────────────────────────────────────────────┐
 │  trigger: bench CLI (anywhere) · Step Functions console · EventBridge Scheduler        │
 │        ▼                                                                               │
 │  Step Functions  bench-run · bench-maintenance                                          │
 │        │  Lambda: discover-lab · dispatch (SSM in any region) · collect-cloudwatch ·    │
 │        │          finalize · stage-vendor (downloads OTel/node_exporter/Harvest)        │
 │        ▼                                                                               │
 │  S3 bench store ──► Glue catalog ──► Athena ──► review dashboard (Grafana OSS, §7)      │
 │        ▲  ▲ read by finalize                                                               │
 └────────┼──┼────────────────────────────────────────────────────────────────────────────┘
          │  └──────────── S3 staging bucket (cache region, only when cross-region)
          │                        ▲
 ┌────────┼──── LAB (per campaign) ┼──────────────────────────────────────────────────────┐
 │  ORIGIN VPC (origin region)     │            CACHE VPC (cache region)                  │
 │  origin worker                  │            cache worker                              │
 │   bench-agent: fio, fileops     │             bench-agent: fio, fileops                │
 │   OTel Collector ── S3 (home)   └──────────── OTel Collector ── S3 (staging)           │
 │   node_exporter                               node_exporter                            │
 │   Harvest (polls both clusters)                                                        │
 │        │ NFS v3 / v4.1                              │ NFS v3 / v4.1                    │
 │  FSx Origin  vol_origin ◄──────── FlexCache ───────► FSx Cache  vol_cache              │
 └────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Who does what

| Component | Where | Job |
|---|---|---|
| **Workers** | the two lab EC2 instances, found by tag `BenchRole = origin \| cache` + `BenchLab = <creator>-<project>` | All I/O (datasets, fio, fileops) and all in-VPC telemetry. |
| **`bench-agent`** | both workers, installed by stack 05 over SSM from `s3://…/agent/current/` | `start <job>` as a detached `systemd-run` unit, `status`, `stop`, `update`. Starts/stops the OTel Collector for a run, controls caches and mounts, uploads results. |
| **OTel Collector** | both workers, only during a run | One pipeline for all environment telemetry (§5.5), written to S3 as OTLP. |
| **Step Functions** | platform | Runs a test suite step by step (datasets are manual, §4): discover lab, snapshot it, send jobs, wait, collect CloudWatch, finalize. |
| **Lambda `dispatch`** | platform, outside any VPC | SSM `SendCommand` / `GetCommandInvocation` in the worker's region (cache worker may be in another region). |
| **Lambda `discover-lab`** | platform | Finds workers, FSx file systems, SVMs, volumes and endpoints by tags in both regions. No Terraform state needed. |
| **Lambda `collect-cloudwatch`** | platform | `ListMetrics` + `GetMetricData` for the step window: `AWS/FSx` (both file systems, both regions) and `AWS/EC2` (both workers). |
| **Lambda `finalize`** | platform | Raw files + OTLP → Parquet, Glue partitions, summary rows. |
| **Lambda `stage-vendor`** | platform (has internet) | Downloads pinned versions of otelcol-contrib, node_exporter and Harvest, checks their checksums, puts them in `s3://…/agent/vendor/` (and the staging bucket). Workers install from there. |

### 2.2 Life of a test step

```
Step Functions                         worker (bench-agent)                         S3
──────────────                         ────────────────────                         ──
dispatch → SSM: bench-agent start s3://…/runs/<run>/jobs/<step>.json
                                       download job, check cache state,
                                       mount (NFS version of the step),
                                       drop client caches,
                                       wait for start time (barrier, UTC)
                                       OTel Collector running for the run ────────► runs/<run>/otel/…
                                       fio | bench-fileops ───────────────────────► runs/<run>/raw/…
Wait 30 s ◄─ poll status.json ◄─────────────────────────────────────────────────── status/<worker>/<step>.json
                                       done: final upload, status=done
wait for CloudWatch delay (5 min) → collect-cloudwatch ───────────────────────────► runs/<run>/raw/cloudwatch/
finalize ─────────────────────────────────────────────────────────────────────────► runs/<run>/curated/ + Glue
next step …
```

Jobs are detached on the worker and polled through S3: nothing holds a connection for hours, and a
Step Functions retry or SSM agent restart doesn't lose a job. `bench stop <run>` stops both workers.

### 2.3 Starting things

From anywhere with the right IAM role (workstation, CloudShell, CI):

```bash
bench run --suite open-latency --dataset ds-mixed-500g-… --side both
bench status <run-id>
bench review                                                # opens the dashboard (§7)
```

`bench` is a thin Python CLI (boto3): validates the profile, uploads the request to
`s3://…/requests/`, calls `StartExecution`. The same JSON works in the Step Functions console or on
an EventBridge Scheduler schedule.

Datasets are **not** started this way: users create them by hand on the clients (§4). A run only
names an existing dataset.

### 2.4 Lock, pre-flight, cleanup, dry-run

- **One run per lab.** `bench-run` takes a lock (`labs/<lab>/lock.json`, written with an S3
  conditional put) and refuses to start while another run holds it. `bench unlock` clears a stale
  lock. A user writing a dataset by hand during a run would distort it, so once the store exists
  `bench-dataset create` / `modify` check the lock and refuse while a run holds it; until then,
  users coordinate.
- **Pre-flight** before the first step: both agents online, mounts possible with the requested NFS
  versions, free space, no leftover bench mounts or collectors, instance type not burstable (warn),
  FSx not inside its weekly maintenance window, clocks in sync.
- **Cleanup always runs** (Step Functions `Catch` → cleanup state, also on `bench stop`): stop
  fio/fileops and the collector, unmount `/mnt/bench/*`, restore the permanent mounts, delete
  scratch files, mark the run `failed` or `stopped`, release the lock. Cleanup is idempotent;
  `bench cleanup` runs it by hand.
- **`--dry-run`** on `run` prints the expanded step list, the space needed,
  the estimated duration (from FSx throughput capacity and earlier runs) and the estimated lab
  cost for that time, without starting anything.

### 2.5 Where the platform sits in the stack order

```
stacks:   01-landing-zone ──► 02-fsxn ──► 03-ec2 ──► 04-flexcache ──► 05-bench (optional)
```

- **Optional.** `deploy_bench = false` (the default in `common.tfvars`) and stack 05 is simply not
  applied: stacks 01-04 are a complete lab on their own, exactly as today. Nothing in 01-04 depends
  on stack 05.
- **Stack 05 does the attaching.** Because it comes last, it can't rely on the workers' boot
  script. It reads the outputs of 01-04 and, like stack 04 does for FlexCache, uses SSM Run Command
  to prepare the workers. It has three parts:

  | Part | Contents | Lifetime |
  |---|---|---|
  | **Store** | S3 buckets (home + staging), Glue/Athena tables, dashboards | Kept across labs. Buckets have `prevent_destroy`. |
  | **Engine** | Step Functions, Lambdas, review Grafana, IAM roles | Cheap to recreate; can stay or go. |
  | **Lab attachment** | Bench IAM policy on the two worker roles, worker tags, packages + `bench-agent` + vendor binaries installed over SSM, the `bench-monitor` ONTAP user | Tied to one lab. |

- **Tearing a lab down** is the one place the "highest number first" rule changes:

  ```bash
  ./tf.sh 05-bench detach     # removes only the lab attachment; store and engine stay
  ./tf.sh 04-flexcache destroy         # then 03, 02, 01 as usual
  ```

  A new lab later: apply 01-04, then `./tf.sh 05-bench apply` attaches the bench to the
  new workers. All earlier dataset specs, runs and dashboards are still there.
- **Removing everything** (`./tf.sh 05-bench destroy`) removes engine and attachment but
  stops at the buckets; deleting the results is a separate, explicit step.
- Reviewing old runs (`bench review`) needs only the store and engine, not a lab.

### 2.6 The four modules

The bench is four modules, used in this order. Each has its own code folder, its own `bench`
command group and, where it needs AWS resources, its own Terraform module inside stack 05.

| # | Module | What it does | Command | AWS resources | Details |
|---|---|---|---|---|---|
| 1 | **Dataset** (manual) | Plans and writes the files (count, size, total), from the origin or the cache side; modifies, verifies and deletes them; keeps the manifest. **Run by hand by the users on the clients.** | `bench-dataset …`, `bench-datasets-nfs` | none of its own | §4 |
| 2 | **Tooling** | Builds what the tests need: `bench-agent`, fio, `bench-fileops`, the collectors (OTel, node_exporter, Harvest) on the two workers, and the engine that drives them (Step Functions, Lambdas, lock, pre-flight, cleanup). | `bench tooling install \| check \| update \| remove` | Step Functions, Lambdas, IAM, worker attachment | §2.1-2.4 |
| 3 | **Run** | Runs the performance tests: suites, workloads, side switch, NFS version, cache state, repetitions. Produces raw results and telemetry. | `bench run …`, `bench status`, `bench stop` | none of its own (uses Tooling) | §5 |
| 4 | **Observe** | Turns saved results into tables and shows them: Athena tables, Grafana, the five dashboards, reports. | `bench observe attach \| open \| detach`, `bench report` | Glue/Athena, review Grafana | §6.2, §7 |

Underneath all four sits the **results store**: the S3 bucket(s) of §6.1. It is deliberately
**not** part of Observe.

```
 1 Dataset ──┐
 2 Tooling ──┼──► writes ──►  RESULTS STORE (S3, kept)  ◄── attaches ── 4 Observe (disposable)
 3 Run ──────┘                specs, manifests, lab snapshots,
                              raw results, telemetry, curated tables
```

**Dependencies.** Dataset is **standalone and manual**: it needs only the delivery of §2.7 (the
commands on the clients) and its own Python writer, not Tooling's agent or engine. Run executes
through Tooling and only *reads* datasets: it takes a dataset id and the manifest from the
dataset's records. Observe depends on nothing but the store.

**Save now, observe later.** This is how module 4 is built:

- Everything Observe shows is **derived from files in the store**. Observe itself holds no data:
  Glue table definitions, the Athena workgroup and the Grafana instance can all be deleted.
- `bench observe detach` (or destroying the Observe Terraform module) removes them. The store, and
  so every result, stays. With Observe gone the platform costs only S3 storage.
- `bench observe attach [--store s3://bucket]` recreates Observe and points it at a store: it
  creates the tables, registers every run found under `runs/*/curated/` as a partition, rebuilds
  `curated/` from `raw/` for any run that lacks it, and provisions the dashboards from Git. The
  store can be the original bucket or a **copy of it** (another bucket, account or region), so
  results can be archived or handed over and attached somewhere else.
- `bench results export <run|campaign> --to s3://…` copies a self-contained subset (runs with their
  dataset manifests and lab snapshots) for that purpose.
- Observe needs no lab and no Tooling: results from a lab destroyed months ago attach the same way.

In stack 05 the parts of §2.5 map to the modules: **Store** = results store, **Engine** + **lab
attachment** = Tooling, and Observe is its own part with its own switch (`deploy_observe`).

### 2.7 Delivery to the clients (built)

The clients have no internet, so they can't clone the repository. `stacks/05-bench` calls
`modules/09-bench-deploy`, which works like the FlexCache module: Terraform runs a script on the
operator machine that packs `bench/` and `profiles/` and sends them over SSM Run Command to each Linux client.
The client unpacks them into `/opt/bench`, records the Git commit in `/opt/bench/VERSION.json`,
installs the `bench-dataset` command and runs the bench's tests. Any change to the files re-deploys
on the next apply; nothing is sent otherwise.

This is the first piece of stack 05. The store, engine and Observe parts of §2.5 are added to the
same stack later, as `modules/10-…` onwards. The bundle travels inside one SSM command (limit
~60 KB); once Tooling brings the S3 store, delivery moves to S3 and the limit goes away.

### 2.8 Results volume and telemetry (built)

**Results: an FSx for ONTAP volume, not S3.** `modules/12-bench-results-volume` creates
`vol_bench` (FlexVol, 100 GiB, UNIX, storage efficiency on, tiering `NONE`) on the origin file
system, or the cache one (`results_volume.side`). Both clients mount it at `/mnt/fsxn/vol_bench`;
the other side mounts it across the peering. Everything the bench records goes there:

```
/mnt/fsxn/vol_bench/
  telemetry/<lab>/<side>/<instance-id>/metrics*.json   OpenTelemetry Collector, OTLP JSON, one batch per line
  datasets/<dataset-id>/                              dataset records, shared by all users and both clients
  logs/                                               bench-datasets-nfs --background
  labs/<lab>/lab.json                                 regions, file systems, clients, results volume
```

**Outliving the lab: the final backup.** `skip_final_backup = false`, so deleting the volume
(destroying stack 05, which must come before 02-fsxn) makes FSx back it up first, tagged
`Purpose = bench-results` and `Lab = <lab>`. The backup is independent of the file system.
Restoring it into a new lab (as a read-only volume to review, next to a fresh `vol_bench`) is the
next piece for G4; it replaces the S3 store, Glue tables and `observe attach` of §6 and §2.6.

**S3 only for software.** The clients have no internet, so `stacks/00-bench-store`
(`modules/10-bench-store`) keeps a package bucket per region in use, holding only
`vendor/otelcol-contrib/<version>/*.rpm`; the clients may only read `vendor/*`. It stays between
labs so the package isn't downloaded again each time.

**Staging, then copying.** Writing results to `vol_bench` during a test would add NFS load to the
file systems being measured (the origin file system, by default). So during a test everything is
written to the client's local `/var/lib/bench/staging` and `bench-results-sync` (`bench/results/
sync.py`, root) copies it to `vol_bench` afterwards: at the end of each `bench-dataset` command and
each `bench-datasets-nfs` batch, by hand, and once more on destroy (Collector stopped first; a
failed final copy stops the destroy). Dataset records move to `vol_bench` (a running command holds
a lock, and its folder is skipped); a later command reads them back before it starts. Local
telemetry is capped (2 GiB) so an idle lab can't fill the client's disk. The Run module will copy at
the end of each run in the same way.

**Telemetry: `modules/11-bench-telemetry`, called by stack 05 (`telemetry = true`).**

- **OpenTelemetry Collector** (`otelcol-contrib`, pinned release, SHA-256 checked on the operator
  machine and again on the client). `hostmetrics` (CPU, memory, load, disk, network, paging) every
  5 s; OTLP/HTTP receiver on `127.0.0.1:4318`; **file exporter** to local staging, rotated every
  50 MiB, copied to `vol_bench` after tests.
- **bench-probe** (`bench/telemetry/probe.py`, stdlib) instead of node_exporter: NFS ops/s, RTT
  and execute time per operation and mount from `/proc/self/mountstats`, ENA allowance counters
  from `ethtool -S`, ping to both file systems' NFS IPs, sent to the Collector over OTLP.
- **Continuous, not per run.** The Collector runs whenever the lab is up and every point carries
  `bench.lab`, `bench.side`, `host.id`; a dataset or run is matched to the telemetry by **time
  window and host**. Run ids are added as events by the Run module.
- **Not yet:** ONTAP-level metrics from inside the cluster (Harvest, cluster peer ping); FSx for
  ONTAP's own CloudWatch metrics and the consolidated report are the next pieces. With no results
  in S3, the report reads the results volume (it runs on a client) and pulls CloudWatch for the
  same time window.

## 3. Concepts and identifiers

| Object | What it is | ID example |
|---|---|---|
| **Lab snapshot** | The lab at the start of a run: regions, cross-region yes/no, FSx file systems/SVMs/volumes (`describe-*`), ONTAP version, FlexCache settings (incl. write-back), NFS protocols enabled on the SVMs, worker instance types, kernel, mount options, tfvars copy if published. | `lab-20261110-1402` |
| **Worker** | One of the two lab instances: `origin` or `cache`. | `pedro-cache-client` |
| **Dataset spec** | YAML recipe: count/size/total, layout, data pattern, seed. In Git, published to `s3://…/profiles/`. | `datasets/mixed-500g.yaml` |
| **Dataset instance** | A spec materialized on a lab's volume, with manifest and creation metrics. Dies with the lab; spec + seed recreate it. | `ds-mixed-500g-20261110-1415` |
| **Dataset generation** | A change applied to an instance (e.g. 10 % of files modified from the cache). | `ds-…-1415@g2` |
| **Workload** | One fio job or one bench-fileops job. | `workloads/open-read-close-4k.yaml` |
| **Suite** | Ordered list of **steps**; step = workload + side + NFS version + cache state + repetitions. | `suites/open-latency.yaml` |
| **Run** | One execution of a suite (or one workload) against a dataset instance on a lab snapshot. | `run-20261110T1432Z-open-latency-7f3a` |
| **Campaign** | A label grouping runs ("128 vs 512 MB/s", "same-region vs cross-region"). | `camp-2026-11-cross-region` |

Every run stores its **fully resolved** configuration (profile contents, lab snapshot, agent,
collector and platform versions, Git commit).

## 4. Datasets (G1)

### 4.1 Sizing inputs

Everything in this section is done **by hand by a user** logged in to the client that has the
volume mounted (normally the origin client). The step-by-step procedure for users is in the
top-level README ("Creating the datasets").

`files × mean size = total`: any **two** are given, the third is derived (all three must agree
within 1 %).

```bash
bench-dataset create --files 100000 --file-size 64KiB                 # total derived: 6.1 GiB
bench-dataset create --total 600GiB --file-size 1GiB                  # files derived: 600
bench-dataset create --total 500GiB --file-size 1MiB-64MiB            # uniform range
bench-dataset create --files 50000  --size-mix "70:4KiB-64KiB,25:1MiB-16MiB,5:1GiB"
```

The plan is checked against the volume's free space (10 % margin) and given an ETA from the FSx
throughput capacity before anything is written. With the lab defaults (`vol_origin` 800 GiB,
FlexCache 500 GiB, 128 MB/s) a dataset can't exceed ~700 GiB, and 1 TiB would take over two hours
to write; bigger datasets need a bigger lab first. `bench-dataset delete <id> --yes` removes an
instance's files and frees the space (the manifest and metrics stay in the records).

### 4.2 Spec file

```yaml
# profiles/datasets/mixed-500g.yaml
name: mixed-500g
size:
  total: 500GiB                  # any two of total / files / file_size
  file_size:
    mix:                         # or  fixed: 1MiB   or  range: [1MiB, 64MiB]
      - { weight: 70, range: [4KiB, 64KiB] }
      - { weight: 25, range: [1MiB, 16MiB] }
      - { weight: 5,  fixed: 1GiB }
layout:
  files_per_dir: 1000
  depth: 2                       # d00/d01/f000123.dat
data:
  pattern: random                # random | compressible | dedupable
  compress_percent: 0            # vol_origin has storage efficiency on: keep 0 for honest numbers
  dedupe_percent: 0
seed: 42                         # same seed = same names, sizes, contents
writers:
  side: origin                   # origin (default) | cache
  nfs: v3                        # v3 | v4.1
  threads: 16
  block_size: 1MiB
  checksums: sample              # none | sample (1 %) | all
```

### 4.3 How it is written (built)

- **On the client, in one command:** `bench-dataset create` expands the spec into a deterministic
  file list from the seed (the manifest), checks the free space, creates the directories and writes
  the files with parallel writer processes. Same spec + seed = same names, sizes and bytes.
- **Writer:** standard-library Python, so it runs on Amazon Linux without installing anything.
  **Every file's open, write, fsync and close is timed**, so creating a dataset is also a recorded
  metadata + write test. Python adds a few microseconds per call, which is fine at the
  millisecond scale of NFS writes; the cold/warm *open* measurements of §5.3 still use the C
  `bench-fileops`.
- **Records**, in `~/bench-results/datasets/<id>/` of the user who ran it (or `$BENCH_OUT`):
  `dataset.json` (resolved spec, side, mount and NFS options, host, kernel, timings, throughput,
  latency percentiles per generation), `manifest-g<N>.csv.gz` (path, size, SHA-256, state) and
  `ops-g<N>.csv.gz` (one row per file operation). Once the store exists, `bench-dataset` also
  uploads them to `datasets/<id>/` so Run and Observe can find them.
- `--resume` continues an interrupted create; `--dry-run` writes nothing.

### 4.4 Writing from the cache side

By hand, on the cache client, `bench-dataset modify --side cache --target /mnt/fsxn/vol_cache` (or a spec with `writers.side: cache`) writes through `vol_cache` from the
cache worker. FlexCache forwards the writes to the origin (write-around today; write-back later,
§0), so this measures the write path across the peering – across regions in a cross-region lab.

```bash
bench-dataset modify ds-… --side cache --mode create    --total 50GiB --file-size 4MiB   # new files under _cache_writes/
bench-dataset modify ds-… --side cache --mode overwrite --percent 10 --range random     # rewrite parts of 10 % of files
bench-dataset modify ds-… --side cache --mode append    --percent 5  --bytes 1MiB
bench-dataset modify ds-… --side cache --mode metadata  --percent 2  --ops rename,chmod,delete
```

Each modify is a new **generation** with its own manifest delta. `--verify` re-reads the touched
files on the origin worker and compares checksums (sample), which also measures how long a
cache-side change takes to be visible at the origin.

### 4.5 T-shirt sizes (built)

Six profiles in `profiles/datasets/`, created by hand with `bench-datasets-nfs <size>…` on an NFS
mount, one dataset per size:

| Size | File size | Total | Files |
|---|---|---|---|
| `small` | 64 KiB | 10 GiB | 163 840 |
| `2xsmall` | 1 MiB | 50 GiB | 51 200 |
| `medium` | 5 MiB | 100 GiB | 20 480 |
| `2xmedium` | 10 MiB | 200 GiB | 20 480 |
| `large` | 50 MiB | 250 GiB | 5 120 |
| `2xlarge` | 1 GiB | 300 GiB | 300 |

All six are 910 GiB, more than the default 800 GiB `vol_origin`; the script checks the space for
the whole selection first. `--scale` gives trial runs, `--background` survives logging out.

### 4.6 What manual datasets mean for the test runs

- A run **never creates or deletes** a dataset. It checks that the named dataset exists, that its
  manifest matches the files (sample), and that it is big enough for the suite; if not, it stops
  and says which dataset (size, or how many never-seen files for cold steps) the user should create.
- Cold-cache steps use up never-read files (§5.3). When a dataset has none left, the user creates
  a new one (or a new generation) by hand.
- The `origin-change` step of `open-latency` (changing 5 % of the files at the origin during the
  suite) is part of the *measurement* of invalidation, so it stays inside the run. It works on
  files the run writes itself under `_bench/<run>/`, never on the user's dataset files.

## 5. Performance tests (G2)

### 5.1 The side switch and the NFS version

```bash
bench run --suite cache-read     --dataset ds-… --side cache
bench run --workload seq-read-1m --dataset ds-… --side origin --nfs v4.1
bench run --workload rand-rw-4k  --dataset ds-… --side both                    # one after the other (default)
bench run --workload rand-rw-4k  --dataset ds-… --side both --concurrent       # at the same time
bench run --suite open-latency   --dataset ds-… --side cache --nfs v3,v4.1     # whole suite once per version
```

| `--side` | Worker | Path |
|---|---|---|
| `origin` | origin | `vol_origin` |
| `cache` | cache | `vol_cache` (FlexCache) |
| `cache-direct` | cache | `vol_origin` over the peering, no FlexCache – the baseline (needs `cache_mounts_origin = true`) |
| `both` | both | origin + cache |

**NFS version and mounts:** each step mounts its own mount point, `/mnt/bench/<run>/<step>`, with
the step's options (`vers=3` or `vers=4.1`, plus anything else: `nconnect`, `actimeo`, `nocto`…),
and unmounts it after. A second mount is **not** automatically clean: by default Linux shares one
cache between all mounts of the same export, and the first mount to a server fixes `nconnect` for
the later ones. So for the duration of a run the agent **unmounts the permanent `/etc/fstab`
mounts** (and stops the remount timer), leaving the step's mount as the only one to that server;
cleanup restores them. A "dropped" client cache is then: unmount, `drop_caches`, mount. Phase 0
proves this with `mountstats` (a first open after remount must show `LOOKUP`s on the wire). With
`--nfs v3,v4.1` the runner expands every step once per version, so the dashboard can compare them
side by side.

With `--concurrent` both workers get the same start time (now + 30 s, UTC) and wait for it. They
use Amazon Time Sync (chrony), so samples from both sides – also across regions – line up.

### 5.2 Throughput, IOPS, latency – fio

```yaml
# profiles/workloads/rand-read-4k.yaml
name: rand-read-4k
engine: fio
fio:
  rw: randread           # read | write | randread | randwrite | randrw (+ rwmixread)
  bs: 4k
  iodepth: 32
  numjobs: 8
  direct: 1
  ioengine: libaio
  runtime: 300s
  ramp_time: 30s
  time_based: true
  file_scope: dataset    # the dataset's files | scratch: own files under _bench/<run>/
log_interval: 1s
```

Starter set: `seq-read-1m`, `seq-write-1m`, `rand-read-4k`, `rand-write-4k`, `rand-rw-70-30-4k`,
`lat-read-4k-qd1`, `lat-write-4k-qd1`. Captured: throughput, IOPS, latency mean and
p50/p90/p99/p99.9, read and write separately, per second and per step.

### 5.3 File open / close latency – `bench-fileops`

fio measures I/O on files it already opened; it doesn't report how long `open()` or `close()`
took. On a FlexCache that is where cold and warm differ most: a cold open makes the cache fetch the
file's metadata from the origin across the peering, a warm open is answered by the cache.

**What it is:** a small C program (`agent/fileops/fileops.c`, built on the worker at agent install
with `gcc` from the Amazon Linux repos). C rather than Python because a warm open served from the
client's caches takes microseconds, which Python's overhead would blur. Each operation is timed with
`clock_gettime(CLOCK_MONOTONIC)` around the system call and stamped with wall-clock time.

**Per file, in order, each timed separately:**

| Phase | Call | Notes |
|---|---|---|
| `stat` | `stat()` | optional, before open |
| `open` | `open(O_RDONLY)`, or `O_WRONLY \| O_APPEND`, or `O_CREAT \| O_EXCL` | the main measurement |
| `first_io` | first `read()` / `write()` | time to first byte |
| `io` | the rest of the read/write | `bytes: 0` = open+close only, `first` = first block, `all` = whole file |
| `fsync` | `fsync()` | write modes, optional |
| `close` | `close()` | on NFS, close flushes dirty data (close-to-open), so it is slow after writes |

Plus per directory, optional: `opendir` + `readdir`.

**Modes:** `open-close` (pure metadata), `open-read-close`, `open-write-close`, `create` (also the
dataset writer), `stat`.

**Options:** threads; file selection (all, random sample of K, one size bucket of the mix); order
(`manifest`, `shuffled` with seed, `by-directory`); passes (same file list N times in a row); minimum
duration; rate limit (ops/s, to measure latency below saturation). Under a rate limit each
operation has a **scheduled** start time and latency is also measured from it (`lat_sched_ns`), so
a stall shows up in the numbers instead of being hidden by the operations that never got sent
(coordinated omission).

**Output per step:**

- `fileops.csv.gz`: one row per operation – `ts`, `worker`, `thread`, `pass`, `file_idx`, `op`,
  `lat_ns`, `bytes`, `errno`. 1 M files × 4 phases ≈ 4 M rows, a few tens of MB compressed.
- `fileops-summary.json`: count, mean, p50/p90/p99/p99.9/max per `op` × `pass`, ops/s.
- `mountstats` before/after each pass, so each pass has the **NFS operations behind it**. This is
  where v3 and v4.1 differ:

  | | `open()` on the wire | `close()` on the wire |
  |---|---|---|
  | NFSv3 | `LOOKUP` (if not in the dentry cache) + `ACCESS` + `GETATTR` (close-to-open revalidation) | nothing after a read; `WRITE`/`COMMIT` of dirty data after a write |
  | NFSv4.1 | `OPEN` (inside a `SEQUENCE` compound, with `GETATTR`); a delegation, if granted, lets later opens stay local | `CLOSE` (+ flush of dirty data); skipped while holding a delegation |

- Optional (`trace: true`): a `bpftrace` probe on `nfs_file_open` / `nfs4_file_open` /
  `nfs_file_release` as an in-kernel cross-check.

#### Cold vs warm: two caches

| Layer | Cold | Warm |
|---|---|---|
| **FlexCache** (FSx Cache) | File never accessed through this FlexCache: a fresh dataset instance or generation, or a recreated FlexCache. | File accessed through the cache since it last changed at the origin. |
| **Linux NFS client** (worker) | Unmount, `drop_caches`, mount (§5.1) before the pass. | No drop: dentry/attribute caches (and v4.1 delegations) answer what they can. |

"Warm" on the FlexCache has **levels**, because metadata and data are cached separately and data is
cached per block. Every warm step declares which one it means, and the warm-up pass before it
produces exactly that:

| `flexcache:` | The files were previously… |
|---|---|
| `warm-meta` | opened and closed only (`open-close`) |
| `warm-first` | opened and their first block read |
| `warm-full` | read completely |

```yaml
# profiles/suites/open-latency.yaml   – run with --nfs v3,v4.1
name: open-latency
dataset_scope: { order: shuffled, seed: 7 }
min_step_duration: 180s    # see §5.6: long enough for the 1-minute and 15-second sources
cold_subsets: 5            # 5 disjoint file sets, so the cold step has 5 independent repetitions
steps:
  # open on the origin itself
  - { name: origin-baseline,   workload: open-read-close-4k, side: origin,       client_cache: dropped }
  # origin across the peering, no FlexCache
  - { name: cache-direct,      workload: open-read-close-4k, side: cache-direct, client_cache: dropped }
  # first touch through FlexCache: metadata comes from the origin
  - { name: cache-cold,        workload: open-read-close-4k, side: cache, flexcache: cold, client_cache: dropped, repetitions: per-subset }
  # same files again: served by FlexCache
  - { name: cache-warm,        workload: open-read-close-4k, side: cache, flexcache: warm-first, client_cache: dropped, repetitions: 3 }
  # same files, client caches kept: the floor
  - { name: cache-warm-client, workload: open-read-close-4k, side: cache, flexcache: warm-first, client_cache: kept,    repetitions: 3 }
  # 5 % of the files changed at the origin, then opened on the cache
  - { name: origin-change,     action: modify, side: origin, percent: 5 }
  - { name: cache-invalidated, workload: open-read-close-4k, side: cache, flexcache: warm-invalidated, client_cache: dropped }
```

`open-close` (no data) and `open-write-close` variants separate metadata cost from data cost.
A cold step can read each file only once, so its file sets are **disjoint**: one per repetition
(`cold_subsets`) and per NFS version. The subset size comes from `min_step_duration` and the cold
rate measured on a small calibration subset, so the runner knows how many never-seen files the
dataset must hold and says so in `--dry-run`. Warm steps loop over their list until the minimum
duration is reached.

#### Getting a cold FlexCache

| Way | When |
|---|---|
| **New dataset generation** (default) | A new instance under a new directory: never seen by the cache. A few minutes for a 20 000-file sample. |
| **Recreate the FlexCache** (`flexcache: recreate`) | The origin worker runs the stack 04 script (`flexcache.py delete` then `create`, same settings; ~5-10 min). Terraform's state is unaffected because the volume is recreated identically. The cache worker's mounts of the old volume are stale afterwards, so the agent unmounts them **before** the delete and mounts again after the create. |
| **Prepopulate** (`flexcache: prepopulated`) | `volume flexcache prepopulate` on the dataset path – for pre-warmed scenarios (to verify on FSx). |

**Cold is shown, not assumed.** ONTAP has no "is this file cached" query, and the bench can only
know what it read itself. So:

- The store keeps, per dataset generation, which file sets the bench has read through the cache;
  the runner refuses a `cold` step on a set it has already used. This is bookkeeping, not proof
  (someone running `ls -lR` on the cache mount by hand defeats it).
- Every cache step records **evidence**: the cache volume's used space and the FlexCache counters
  (Harvest) before and after, and the NFS op counts. A cold pass must show the cache volume growing
  and origin traffic; a warm pass must show neither. `finalize` checks this and flags a step whose
  evidence contradicts its label (`cache_state_verified: false`); the dashboards show the flag.

### 5.4 Other suites

`origin-baseline` (all fio workloads on the origin), `cache-read` (fio: origin, cache-direct, cache
cold, cache warm), `cache-write` (writes from the cache vs the origin), `contention` (origin writes
while the cache reads the same files), `quick-check` (2-minute smoke test of a new lab). Later:
`writeback` (same as `cache-write` with write-back on, §0).

### 5.5 What is captured, and how

Two kinds of data, kept apart on purpose:

- **Test results** – fio and fileops output. Written by the agent **straight to S3** as files:
  they are the measurement, they are bulky (per-op rows), and they don't need a telemetry pipeline.
- **Environment telemetry** – everything around the test. Goes through the **OpenTelemetry
  Collector** (§7.2) on both workers for the whole run, so an origin test also shows on the cache
  worker's telemetry.

| Source | Collected by | What | Interval |
|---|---|---|---|
| **fio** | agent → S3 files | JSON summary + per-second bw / IOPS / latency logs | 1 s |
| **bench-fileops** | agent → S3 files | per-operation latency + mountstats per pass | every op |
| **Host** | OTel `hostmetrics` receiver | CPU (user/sys/iowait/steal), memory, NIC bytes/packets/errors, load, paging | 1 s |
| **NFS client** | node_exporter `mountstats` + `nfs` collectors → OTel `prometheus` receiver | per mount: ops/s, RTT and execute time per NFS op | 5 s |
| **ENA limits** | node_exporter `ethtool` collector → OTel | `bw_in/out_allowance_exceeded`, `pps_allowance_exceeded`, … – shows when the EC2 instance is the bottleneck | 5 s |
| **ONTAP** | **NetApp Harvest** on the origin worker (polls both clusters) → OTel `prometheus` receiver | volume latency / IOPS / throughput (`vol_origin`, `vol_cache`), node CPU, LIF traffic, FlexCache counters (Harvest's FlexCache dashboard is supported on FSx but off by default) | Harvest poll, set to 15-30 s for tests |
| **Cluster peer ping** | agent (ONTAP REST CLI passthrough, origin worker) → OTLP | RTT between Origin and Cache intercluster LIFs – the latency between the two systems, the key number cross-region | 10 s |
| **Worker ↔ LIF ping** | agent → OTLP | ICMP RTT to own SVM NFS IP; cache worker also to the origin NFS IP | 5 s |
| **Events** | agent → OTLP logs; Step Functions → S3 | step/pass start/end, ramp end, cache drop, mount/unmount, FlexCache recreated, dataset generation, errors, notes (`bench annotate`) | – |
| **CloudWatch** | Lambda, after each step | `AWS/FSx` (every metric `ListMetrics` returns for both file systems and volumes) and `AWS/EC2` (detailed monitoring on) | 1 min |

Latency has three independent views: **client** (fio, fileops, NFS mountstats), **server**
(ONTAP/Harvest, CloudWatch `…OperationTime / …Operations`) and **network** (peer ping, LIF ping).

### 5.6 Making the numbers trustworthy

| Risk | Rule |
|---|---|
| **Steps shorter than the sampling interval.** CloudWatch samples every minute, Harvest every 15-60 s; opening 20 000 warm files takes seconds. | Every step runs for at least `min_step_duration` (default 180 s) with a 60 s pause between steps. Steps are sized by time, not by file count. |
| **Uncontrolled origin state.** Data tiered to the capacity pool, or still in the origin's memory right after a dataset write, changes "cold" latency a lot. | Lab default: tiering policy `NONE` on `vol_origin` (all on SSD). The tiering policy and SSD/capacity-pool usage are in the lab snapshot. Datasets are written at least one step before they are read, and a suite can ask for an origin "settle" pause. A tiered-origin test is a deliberate variant, not an accident. |
| **Cache eviction.** A dataset bigger than the FlexCache makes "warm" unstable. | Pre-flight compares the dataset (and what the suite will read) with the FlexCache size and refuses, unless the suite says `allow_eviction: true` (Q8). Cache used space is recorded throughout. |
| **Monitoring disturbs the test.** Collector, Harvest (origin worker only), per-op logging and `bpftrace` share the CPU and network of the load generator. | `quick-check --telemetry off` vs `on` is run once per lab; the difference is stored with the lab snapshot and shown on the run summary. `bpftrace` stays off by default. Harvest and the collector are CPU-pinned away from the load threads. |
| **Run-to-run noise unknown.** | Each campaign starts with a **noise baseline**: the same suite twice with nothing changed. The compare dashboard shows that spread next to every difference, and marks differences smaller than it. |
| **Too few repetitions.** | Warm steps: 3+ repetitions; cold: `cold_subsets` disjoint sets. Summaries give median and spread across repetitions, not just a mean. |
| **Coordinated omission.** | Rate-limited fileops and fio (`rate_iops`) steps report latency from the scheduled start (§5.3). |
| **The lab changes underneath.** `latest` Amazon Linux means a different kernel and NFS client next campaign; FSx updates ONTAP in its maintenance window. | The AMI ID and fio/collector/Harvest versions are pinned in tfvars and stored in the lab snapshot; `bench lab check` reports any difference from the snapshot a `--rerun` refers to. Pre-flight refuses to start inside the FSx maintenance window. |
| **The worker is the bottleneck, not FSx.** One client per side by decision (§0). | ENA allowance counters and worker CPU are on every summary row; a step where they hit a limit is flagged `client_limited`. Results are labelled "single client". Q4/Q5 numbers above what one instance can drive are out of scope until more clients are allowed. |

## 6. Storage in AWS (G4)

### 6.1 S3 store

One bucket from `05-bench` in the home region: versioning on, SSE-S3, public access
blocked, no expiry.

```
s3://<creator>-<project>-bench-<account>-<home_region>/
  profiles/                            published copy of profiles/ from Git
  agent/<version>/  agent/current      bench-agent bundle, fileops source
  agent/vendor/                        otelcol-contrib, node_exporter, Harvest (pinned, checksummed)
  requests/<id>.json                   what was asked (CLI / console / schedule)
  labs/<lab-id>/                       lab snapshot (no secrets)
  datasets/<dataset-id>/  dataset.yaml  manifest-g<N>.parquet  raw/
  runs/<run-id>/
    run.yaml                           resolved suite + workloads, dataset@gen, lab-id, versions
    jobs/<step>.json  status/<worker>/<step>.json
    raw/<worker>/{fio,fileops}/        test results (files)
    otel/<worker>/…                    OTLP JSON from the collectors (environment telemetry)
    raw/cloudwatch/                    GetMetricData responses
    curated/                           Parquet written by finalize
  campaigns/<campaign-id>.yaml
```

- **Raw is never rewritten.** `curated/` is rebuildable from `raw/` + `otel/`
  (`bench rebuild <run>`), so parsers can improve without losing old runs.
- **Cross-region:** the cache worker's S3 gateway endpoint only reaches buckets in its own region,
  so the platform creates a **staging bucket** in `cache_region` (same prefixes, also persistent).
  The cache worker's agent and collector write there. No replication: the `finalize` Lambda runs
  outside the VPCs and reads both buckets directly, writes `curated/` to the home bucket, and
  copies the cache worker's raw files into the home bucket so a run is complete in one place.
  `stage-vendor` also puts the vendor binaries into the staging bucket.
- **Workers' IAM:** read `profiles/*`, `agent/*`, `runs/*/jobs/*`; write `runs/*`, `datasets/*` –
  in their own region's bucket.

### 6.2 Tables (Glue Data Catalog + Athena)

`finalize` writes Parquet and registers partitions (`run_id`, `dt`) – no crawler.

| Table | Grain | Columns (main) |
|---|---|---|
| `samples` | one value of one time series | `ts`, `run_id`, `step`, `rep`, `nfs`, `source`, `side`, `worker`, `entity`, `metric`, `stat`, `value`, `unit` |
| `fileops` | one file operation | `ts`, `run_id`, `step`, `rep`, `nfs`, `pass`, `side`, `worker`, `thread`, `file_idx`, `size_bucket`, `op`, `lat_us`, `bytes`, `errno` |
| `nfs_ops` | NFS op counts / RTT per pass | `run_id`, `step`, `pass`, `nfs`, `worker`, `nfs_op`, `count`, `avg_rtt_us`, `avg_exe_us` |
| `step_summary` | step × rep × side | throughput, IOPS, latency percentiles (fio); open/close/… percentiles (fileops); cache state; NFS version |
| `events` | one event | `ts`, `run_id`, `step`, `side`, `worker`, `type`, `detail` |
| `runs` | one run | flattened configuration: regions, cross-region, FSx throughput/storage/HA pairs, volume style, FlexCache size and write mode, ONTAP version, instance types, NFS options, dataset spec, suite |
| `datasets` | one generation | spec, size, file count, creation throughput, create/close latency percentiles |

OTLP is converted to the same long `samples` format (metric name + attributes → `source`,
`entity`, `metric`), so Harvest, node_exporter, hostmetrics, pings and CloudWatch all land in one
table and can be plotted against each other.

### 6.3 Re-spinning a lab

```bash
# build the lab as usual (stacks 01-04), then ./tf.sh 05-bench apply: attaches the bench to the new workers
bench lab check                                            # discover-lab + agents online + mounts + NFS v3/v4.1 OK
# a user recreates the dataset by hand on the new lab: same spec + seed = same files
bench-dataset create --target /mnt/fsxn/vol_origin --spec mixed-500g --seed 42
bench run --rerun run-20261110T1432Z-open-latency-7f3a     # same suite on the new lab
```

`scripts/publish-lab-config.sh` (or a `tf.sh` hook) copies the tfvars (no secrets in them) to
`labs/<lab-id>/tfvars/`, so whoever has the Terraform repo can rebuild a lab with the same settings.

## 7. Telemetry and dashboard (G3)

### 7.1 OpenTelemetry: what it gives us and what it doesn't

OpenTelemetry (OTel) is a **standard for collecting and shipping telemetry** – metrics, logs,
traces – with a vendor-neutral protocol (OTLP) and a configurable Collector. It is **not** a store
and **not** a dashboard: OTel data always ends up in some backend that we then look at.

| OTel gives us | OTel doesn't give us |
|---|---|
| One collection pipeline on each worker, configured in YAML instead of custom collectors | Storage – we still need one (S3 + Athena here) |
| Ready receivers: host metrics, Prometheus scraping (node_exporter, Harvest), OTLP from our agent | A dashboard – we still need one (§7.3) |
| Standard data model with attributes (`bench.run_id`, `bench.side`, `bench.nfs`, …) on every point | Test results: fio/fileops output stays as files |
| Backend freedom: adding a second exporter (CloudWatch, Amazon Managed Service for Prometheus, OpenSearch, a SaaS) is a config change, no change on the collection side | |
| An S3 exporter (`awss3exporter` in otelcol-contrib, OTLP JSON, time-partitioned) that writes through the existing S3 gateway endpoint – no new VPC endpoint | |

**So: yes to OTel, as the collection layer.** It replaces most of the custom collectors from v2 and
keeps the backend choice open. It doesn't answer the Grafana question by itself – that is §7.3.

### 7.2 Collector on each worker

`bench-agent` starts the collector at run start with the run's attributes and stops it at run end,
so every data point carries the run it belongs to:

```yaml
# rendered by bench-agent per run; OTEL_RESOURCE_ATTRIBUTES=bench.run_id=…,bench.side=cache,bench.worker=…
receivers:
  hostmetrics:
    collection_interval: 1s
    scrapers: { cpu: {}, memory: {}, load: {}, network: {}, paging: {} }
  prometheus:
    config:
      scrape_configs:
        - job_name: node          # node_exporter: mountstats, nfs, ethtool (ENA allowances)
          scrape_interval: 5s
          static_configs: [{ targets: ["localhost:9100"] }]
        - job_name: harvest       # origin worker only: one Harvest poller per cluster
          scrape_interval: 15s
          static_configs: [{ targets: ["localhost:12990", "localhost:12991"] }]
  otlp:                           # bench-agent: peer ping, LIF ping, events
    protocols: { grpc: { endpoint: "localhost:4317" } }
processors:
  resourcedetection: { detectors: [env, ec2] }
  batch: { timeout: 10s }
exporters:
  awss3:
    s3uploader:
      region: ${env:BENCH_REGION}               # worker's own region
      s3_bucket: ${env:BENCH_BUCKET}            # home bucket, or staging bucket in the cache region
      s3_prefix: runs/${env:BENCH_RUN_ID}/otel/${env:BENCH_WORKER}
      s3_partition_format: "%Y%m%dT%H%M"
    marshaler: otlp_json
service:
  pipelines:
    metrics: { receivers: [hostmetrics, prometheus, otlp], processors: [resourcedetection, batch], exporters: [awss3] }
    logs:    { receivers: [otlp], processors: [resourcedetection, batch], exporters: [awss3] }
```

(Exact keys to be pinned to the otelcol-contrib version we stage; they changed across versions.)

**NetApp Harvest** is NetApp's open-source ONTAP metrics collector, documented by AWS for FSx for
ONTAP. It runs on the origin worker (the only place with REST access to both clusters), polls both
clusters, and exposes Prometheus metrics that the collector scrapes. That saves writing our own
ONTAP poller for everything except `cluster peer ping`.

Harvest and the peer-ping probe do **not** use `fsxadmin`. Stack 04 creates a dedicated ONTAP user
with a **read-only role** on both clusters (`bench-monitor`, as the Harvest documentation
describes for FSx) and stores its password in its own Secrets Manager secret. `fsxadmin` is only
used where it is needed: creating, deleting and recreating the FlexCache.

**What OTel costs here:** three third-party binaries (otelcol-contrib, node_exporter, Harvest) to
stage, pin and update in VPCs without internet, for a pipeline whose only destination today is S3.
That is accepted because it keeps the backend open for live indicators (§7.5). It is also why
telemetry comes **after** the first results in §9: the measurements don't depend on it.

### 7.3 Dashboard options without IAM Identity Center

Priority is **reviewing stored runs later**, so the dashboard reads the S3/Athena store, not a live
metrics backend.

| Option | Review old runs | Correlation on one time axis | Sign-in without Identity Center | Idle cost | Effort |
|---|---|---|---|---|---|
| **A. Grafana OSS on demand** (small EC2, started by `bench review`, reached with SSM port forwarding) + Athena | ✅ every run | ✅ best: shared crosshair, event annotations, heatmaps | ✅ AWS IAM (SSM) + Grafana login; no public IP | ~USD 1-2/month while stopped (EBS); ~USD 0.10/h while open (instance + endpoints) | medium |
| B. Grafana OSS behind an ALB + Amazon Cognito | ✅ | ✅ | ✅ Cognito users (people without AWS access) | ~USD 20+/month (ALB + instance always on) | medium-high |
| C. Amazon QuickSight + Athena | ✅ | ⚠️ separate visuals, no shared crosshair or annotations | ✅ QuickSight users | per user | low |
| D. Amazon OpenSearch Service + Dashboards (native OTel ingestion) | ✅ while the domain exists | ✅ good, strong for per-op exploration | ✅ internal users / Cognito | ~USD 30-60/month always on | medium |
| E. CloudWatch dashboards | ❌ 1-minute data only for 15 days, nothing per-second, no fileops | ⚠️ | ✅ IAM | ~0 | low |
| F. Amazon Managed Grafana | ✅ | ✅ | ❌ needs Identity Center or SAML | per user | low |

**Recommendation: A – Grafana OSS on demand.**

- A `t4g.small` in a small platform VPC, in a **private subnet with no public IP and no internet**,
  like the lab. It reaches AWS through VPC endpoints: S3 (gateway, free) and SSM, Athena and Glue
  (interface endpoints). The interface endpoints cost money per hour, so `bench review` **creates
  them when a review starts and deletes them when it stops**. Nobody can reach the instance except
  through **SSM port forwarding**, which is gated by IAM. Grafana and the Athena plugin are
  installed from `agent/vendor/` in S3.
- Cheaper variant, only if the account's policy allows a public IP: a public subnet with no inbound
  rules and no endpoints. Not the default, because the lab deliberately has no public IPs.
- `bench review` starts the instance, waits for Grafana, opens the port forward and prints
  `http://localhost:3000`; `bench review stop` (or an idle timer, default 2 h) stops it again.
- Data source: the open-source **Grafana Athena plugin** with the instance's IAM role (read-only:
  Athena, Glue, the bench bucket). Grafana login: admin password in Secrets Manager.
- Dashboards are JSON in Git (`dashboards/`), provisioned at boot from S3: the instance is
  disposable, nothing to back up. Harvest's own ONTAP dashboards can be imported as well.
- If people without AWS access must see results, add B later (same Grafana, ALB + Cognito in
  front) – or export a static HTML report per run (`bench report`) to share.

### 7.4 Dashboards

| Dashboard | Shows |
|---|---|
| **Run timeline** | Panels on one shared time axis and crosshair: fio throughput / IOPS / latency (origin vs cache) · open/close latency over time (heatmap from `fileops`) · NFS RTT per op · host CPU / memory / NIC · ENA limits · peer ping and LIF ping · ONTAP volume latency (Harvest) · CloudWatch FSx (both file systems) · CloudWatch EC2. `events` as annotations, steps as regions. Variables: run, step, worker, NFS version. |
| **Open / close latency** | Per step and pass: percentiles of `open`, `first_io`, `close`, `stat`; distribution (histogram / CDF) of cold vs warm vs warm-client vs origin vs cache-direct; **v3 vs v4.1** side by side; split by file size bucket; NFS ops behind each pass (`nfs_ops`). |
| **Run summary** | One row per step × side × NFS version: throughput, IOPS, latency p50/p99, mean ± stdev over repetitions; client vs ONTAP latency vs peer RTT. |
| **Compare** | Pick runs or a campaign and a dimension (side, cache state, NFS version, FSx throughput, instance type, same- vs cross-region…): grouped bars and percentile curves from `step_summary` joined with `runs`. |
| **Catalog** | Every run, dataset and lab snapshot, filterable by any configuration field; links to the S3 raw files and the Step Functions execution. |

### 7.5 Live indicators (later)

Not a priority. When needed, without touching the collection side:

- **Progress:** `bench status` and the Step Functions console already show step, pass, % done.
- **Live metrics:** add a second exporter to the collector – e.g. `prometheusremotewrite` to
  Amazon Managed Service for Prometheus, or `awsemf` to CloudWatch – plus the VPC endpoint it needs,
  and point a Grafana data source at it. The S3 path stays the system of record.

## 8. Code and infrastructure layout

```
bench/
  cli/                       bench command: one group per module
  dataset/                   1  planner, manifests, generations, modify / verify / delete
  tooling/                   2
    agent/                   bench_agent.py, runners (fio, fileops, mounts, cache control), probes
    fileops/fileops.c        open/close latency + dataset writer
    collectors/              OTel collector, node_exporter and Harvest templates
    engine/                  Step Functions definitions; Lambdas: discover_lab, dispatch, stage_vendor, collect_cloudwatch
  run/                       3  suite expansion, step planning, cache-state bookkeeping
  observe/                   4  finalize (raw → tables), attach / detach, report
    dashboards/              Grafana dashboard JSON
profiles/                    datasets/, workloads/, suites/   (published to the store)
modules/09-bench-deploy/     Terraform: delivery to the clients over SSM (built)
modules/10-bench-store/      Terraform: one package bucket (built; called by stack 00)
modules/11-bench-telemetry/  Terraform: results mount, Collector + probe on the clients (built)
modules/12-bench-results-volume/ Terraform: vol_bench with a final backup (built)
modules/13-bench-tooling/    Terraform: engine, IAM, worker attachment over SSM
modules/14-bench-observe/    Terraform: Glue/Athena, review Grafana
stacks/00-bench-store/       calls 10 (built)
stacks/05-bench/             calls 09, 11, 12 (built); later the engine and Observe
```

Changes to the existing lab:

| Where | Change |
|---|---|
| `stacks/05-bench` (new) | Everything in the platform box. Optional, applied after 01-04 (`deploy_bench`). Store, engine and lab attachment as in §2.5; `detach` before a lab teardown. Takes both regions (home + cache) for the staging bucket. IAM: a `bench-operator` role (start/stop runs, review) and a `bench-reader` role (review only); the Step Functions role may send SSM commands **only** to instances tagged `BenchLab` and only the `bench-agent` document. |
| `modules/07-ec2-client` | Only lab-generic changes: `monitoring = true` (EC2 detailed monitoring), output the role name. Everything bench-specific (tags, bucket IAM policy, `fio`, `sysstat`, `gcc`, otelcol-contrib, node_exporter, Harvest, `bench-agent`, `fileops`) is added by stack 05 over SSM, so the module works unchanged without the bench. |
| `stacks/03-ec2` | Default `cache_mounts_origin = true` (needed for `cache-direct`). Bigger default instance type for real numbers (e.g. `c6in.xlarge`); the bench flags runs on burstable types (`t3`). |
| `stacks/04-flexcache` | Keep `flexcache.py` on the origin worker so the agent can recreate the FlexCache. Later: `flexcache_writeback = false` option (§0). |
| `stacks/02-fsxn` | Check / enable NFS v4.1 on both SVMs (phase 0). `vol_origin` tiering policy explicit, default `NONE`. |
| `stacks/03-ec2`, `common.tfvars` | Pin `ami_id` (today: latest Amazon Linux 2023 at apply time) so two campaigns run the same kernel and NFS client. |

## 9. Implementation phases

Ordered so that the **first real numbers come before the platform**. The lab itself has never been
applied to AWS, and the measurement method carries more risk than the automation, so it is proven
by hand first and automated after.

| Phase | Delivers | Done when |
|---|---|---|
| 0 – Lab + spike | Apply stacks 01-04 once (same-region). Check by hand: NFS v4.1 on both SVMs and through FlexCache (numeric IDs, delegations); NFS ops behind `open()` for v3 and v4.1; the mount/cache rules of §5.1; how to see cold vs warm from ONTAP (cache volume used space, FlexCache counters); REST passthrough for `cluster peer ping`; `prepopulate`; ONTAP version and the write-back field. | Every assumption marked "to verify" in this document is confirmed or replaced. |
| 1 – First numbers, by hand | `fileops.c` and a minimal dataset writer, run with plain SSM commands; fio by hand; results copied to an S3 bucket; one Athena query or notebook. Includes a noise baseline and the telemetry-free reference. | Q1 and Q2 have a first answer (cold vs warm open, v3 vs v4.1) with repetitions, and we trust how it was measured. |
| 2 – Agent | `bench-agent` (detached jobs, mounts, cache control, cleanup), reading datasets by id (manifest and size check), cache-state bookkeeping and evidence. Datasets themselves are already built and stay manual (§4). | Phase 1's test runs from one `bench-agent start` per worker and cleans up after a forced failure. |
| 3 – Platform | Stack 05 (home + staging bucket, Step Functions, `dispatch`, `discover-lab`, `plan_*`), lock, pre-flight, cleanup state, `--dry-run`, `bench` CLI, suites with `--side`, `--nfs`, `--concurrent`. | `open-latency` and `cache-read` run end to end from CloudShell, **in a cross-region lab**, with no manual step other than creating the dataset. |
| 4 – Telemetry | `stage-vendor`, OTel Collector, node_exporter, Harvest with the read-only user, peer/LIF ping, `collect-cloudwatch`, telemetry overhead run. | One run holds every source on one clock, and the overhead of collecting it is known. |
| 5 – Tables + review dashboard | `finalize` (incl. cache-state verification and flags), Glue tables, on-demand Grafana, `bench review`, the five dashboards. | An `open-latency` run can be reviewed end to end with the lab destroyed. |
| 6 – Campaigns | Campaign labels, compare dashboard with the noise band, `--rerun`, schedules, `bench report`. | Q6: same-region vs cross-region compared in one view. |
| 7 – Later | FlexCache write-back (Q9); live indicators (§7.5). | – |

The bench's own code is tested without a lab: `fileops` and the agent against a local directory,
the Lambdas and state machines against mocked AWS and a fake agent – the same approach the Terraform
stacks use today.

## 10. Open questions

1. **Test questions (§1.1):** is the draft list Q1-Q9 the right one, and in the right order?
2. **Dashboard:** option A (Grafana OSS on demand, SSM port forwarding) – or must people without
   AWS access open it (then B, or HTML reports)?
3. **Home account / region:** the lab account and origin region (current assumption), or a
   separate tooling account?
4. **Cross-region pairs:** which regions? It sets the expected peer ping RTT.
5. **Lab size for real tests:** which FSx throughput capacity, volume/FlexCache sizes and worker
   instance type? The defaults (128 MB/s, 800/500 GiB, `t3.small`) are for checking the lab, not
   for measuring it.

## 11. Platform cost when idle

| Item | Idle cost |
|---|---|
| S3 (home + staging, versioned) | storage only, a few GB per campaign |
| Step Functions, Lambda, Glue catalog, Athena | pay per use: cents per campaign |
| Review Grafana (stopped `t4g.small` + 20 GiB EBS; endpoints only while open) | ~USD 1-2/month stopped; ~USD 0.10/h while open |
| EventBridge Scheduler | free tier covers it |

The lab (FSx, EC2, endpoints) is unchanged and still destroyed between campaigns.
