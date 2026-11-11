# 09-bench-deploy

Copies the test bench (`bench/` and `profiles/` from this repository) to the Linux EC2 clients and
checks that it works there. The clients have no internet, so they can't clone the repository.
Called by `stacks/05-bench`.

Same pattern as `08-ontap-flexcache`: Terraform runs `files/deploy.sh` **on the operator machine**, which packs
the folders, sends them to each client with SSM Run Command (`AWS-RunShellScript`) and waits. On the
client, `files/remote.sh` runs as root:

1. unpacks into `/opt/bench.new`, then swaps it with `/opt/bench` (a failed unpack never leaves a
   half-updated bench);
2. writes `/opt/bench/VERSION.json`: Git commit, branch, uncommitted changes yes/no, file hash, time;
3. installs `/usr/local/bin/bench-dataset` (any user; records go to `~/bench-results/datasets`);
4. installs `install_packages` with `dnf` (a failure is reported, not fatal);
5. prints Python and PyYAML availability and the `/mnt/fsxn/*` mounts with free space;
6. runs the bench tests (`run_tests`), offline, in temporary folders.

| Resource | Purpose |
|---|---|
| `terraform_data.deploy["origin" \| "cache"]` | Runs `deploy.sh` with `deploy` on create, `remove` on destroy |

No AWS resources are created. Re-deploys when any bench file, either script, the instance ID or a
setting changes; nothing is sent otherwise. On destroy `/opt/bench` and the command are removed;
dataset files on the volumes and `~/bench-results` stay. If a client is already gone, destroy just
says so and continues.

**Limit:** the bundle travels inside one SSM command, which `deploy.sh` keeps under 60 KB (about 33
KB today). Above that it stops with a clear message; delivery through S3 comes with the Tooling
module.

| Variable | Default | |
|---|---|---|
| `clients` | – | `{ origin = { region, instance_id }, cache = {...} }` |
| `source_root` | – | absolute path of the repository root |
| `source_dirs` | `["bench", "profiles"]` | folders to deliver |
| `install_packages` | `[]` | e.g. `["python3-pyyaml"]` for `.yaml` dataset specs |
| `run_tests` | `true` | run the bench tests on each client after deploying |

Outputs: `bench_home`, `bundle_sha256`, `file_count`, `deployed_to`.

Needs on the operator machine: `bash`, `tar`, `base64`, `git` (for the version record) and the AWS CLI with
`ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation`.
