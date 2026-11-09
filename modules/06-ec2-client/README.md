# modules/06-ec2-client — Linux test client

One Amazon Linux 2023 instance in the **same private subnet as the FSx for ONTAP** of its side. Called
by `stacks/03-ec2` once for the origin and once for the cache (each switchable).

**At boot** (user data) it adds every entry of `nfs_mounts` to `/etc/fstab` at `/mnt/fsxn/<name>` with
`_netdev,nofail`, and a systemd timer (`fsxn-mount.timer`) runs `mount -a -t nfs` every minute. So a
path that doesn't exist yet (the FlexCache volume before `stacks/04-flexcache`) doesn't fail the
boot, and is mounted within a minute of appearing. It also remounts after a reboot.

| Client | Mounts |
|---|---|
| origin | `vol_origin` → `/mnt/fsxn/vol_origin` (write the data set) |
| cache | `vol_cache` (FlexCache) → `/mnt/fsxn/vol_cache`; with `cache_mounts_origin = true` also `vol_origin` over the peering as a no-cache baseline |

**Access from your Mac** – no public IP, no internet gateway, no NAT:
- **EC2 Instance Connect** (`enable_eice`, free): an endpoint in the subnet; only it may SSH to the client.
  `aws ec2-instance-connect ssh --instance-id <id> --connection-type eice`
- **SSM Session Manager** (`enable_ssm`): `ssm`, `ssmmessages`, `ec2messages` interface endpoints
  (about USD 0.01/h each) and an instance role with `AmazonSSMManagedInstanceCore`.
  `aws ssm start-session --target <id>`

Both endpoints are per VPC, so each side's client brings its own.

**Tags:** every resource gets the `Creator` tag and a `Name` starting with `<creator>-<project>`
(`pedro-flexcache-perf-origin-client`, `...-sg`, `...-eice`, `...-ssm-endpoint`, `...-root`, `...-role`).

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_id` | required |
| `instance_type` | `t3.small` |
| `architecture` | `x86_64` (`arm64` for Graviton) |
| `ami_id` | latest AL2023 |
| `root_volume_gib` | `8` |
| `enable_eice` / `enable_ssm` | `true` / `true` |
| `nfs_mounts` | `{}` – `name => { server, export, options }`; options default `vers=3,nconnect=8,hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576` |

The **origin** client is also where `stacks/04-flexcache` runs the FlexCache configuration (SSM Run
Command), so keep `enable_ssm = true` for it.

**Outputs:** `instance_id`, `private_ip`, `eice_id`, `mounts`, `connect_eice`, `connect_ssm`, `role_name`, `ssm_enabled`.
