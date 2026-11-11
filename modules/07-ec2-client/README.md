# modules/07-ec2-client — test client (Linux or Windows)

One instance in the **same private subnet as the FSx for ONTAP** of its side. Called by
`stacks/03-ec2` once for the origin and once for the cache (each switchable). `os = "linux"`
(protocol NFS, the default) is Amazon Linux 2023; `os = "windows"` (protocol SMB) is Windows Server 2022.

**Windows** (`user_data.ps1.tftpl`): a scheduled task `fsxn-map` runs every minute as SYSTEM. It reads
the AD Admin secret (`ad_secret`) through a Secrets Manager endpoint in the VPC
(`enable_secrets_endpoint`), sets the local `Administrator` password to the same value once (workgroup
only; with `domain_join` it keeps its random one), and maps
each entry of `smb_mappings` (`share => { drive, server }`) for every user with `New-SmbGlobalMapping`,
retrying until the share exists. The computer is renamed to `hostname` and restarted. With
`domain_join` (`{ domain_name, dns_ips, ou }`) an NRPT rule sends the domain's DNS queries to the
domain controllers, and the task joins the domain into `ou` after the rename, then restarts once
more before mapping. A mapping's optional `fallback` (the SVM IP) is used while `server` (the SVM's
DNS name) doesn't resolve. Log:
`C:\fsxn\fsxn-map.log`. `C:\fsxn` is locked to SYSTEM and Administrators. The IAM policy allows reading
`ad_secret` only in this account and region. The Instance Connect Endpoint opens RDP (3389) instead of SSH, and the
`connect_eice` output is the `open-tunnel` command.

The rest of this page describes the Linux client.

**At boot** (user data) it adds every entry of `nfs_mounts` to `/etc/fstab` at `/mnt/fsxn/<name>` with
`_netdev,nofail`, and a systemd timer (`fsxn-mount.timer`) runs `mount -a -t nfs` every minute. So a
path that doesn't exist yet (the FlexCache volume before `stacks/04-flexcache`) doesn't fail the
boot, and is mounted within a minute of appearing. It also remounts after a reboot. Each mounted
volume's top directory is set to `1777` (like `/tmp`), so non-root logins (`ssm-user`, `ec2-user`) can
write; a stricter mode set by hand is put back to `1777` on the next run.

| Client | Mounts |
|---|---|
| origin | `vol_origin` → `/mnt/fsxn/vol_origin` (write the data set) |
| cache | `vol_cache` (FlexCache) → `/mnt/fsxn/vol_cache`; with `cache_mounts_origin = true` also `vol_origin` over the peering as a no-cache baseline |

**Access from the operator machine** – no public IP, no internet gateway, no NAT:
- **EC2 Instance Connect** (`enable_eice`, free): an endpoint in the subnet; only it may SSH to the client.
  `aws ec2-instance-connect ssh --instance-id <id> --connection-type eice`
- **SSM Session Manager** (`enable_ssm`): `ssm`, `ssmmessages`, `ec2messages` interface endpoints
  (about USD 0.01/h each) and an instance role with `AmazonSSMManagedInstanceCore`.
  `aws ssm start-session --target <id>`

Both endpoints are per VPC, so each side's client brings its own.

**Tags:** every resource gets the `Creator` tag and a `Name` starting with `<creator>-<project>`
(`pedro-flexcache-perf-origin-client-sg`, `...-eice`, `...-ssm-endpoint`, `...-role`). The instance itself uses the
shorter `instance_name` (`pedro-origin-client`, root volume `pedro-origin-client-root`), and `hostname` sets its Linux hostname.

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_id` | required |
| `os` | `linux` (`windows` for SMB) |
| `instance_type` | `t3.small` (Linux), `t3.medium` (Windows) |
| `architecture` | `x86_64` (`arm64` for Graviton, Linux only) |
| `ami_id` | latest AL2023 or Windows Server 2022 |
| `root_volume_gib` | `8` (Linux), `50` (Windows) |
| `enable_eice` / `enable_ssm` | `true` / `true` |
| `nfs_mounts` | `{}` – `name => { server, export, options }`; options default `vers=3,nconnect=8,hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576` |
| `smb_mappings` | `{}` – Windows: `share => { drive, server, fallback }` |
| `domain_join` | `null` – Windows: `{ domain_name, dns_ips, ou }` to join the Managed AD |
| `ad_secret` | `null` – Windows: `{ name }` of the AD Admin secret (required) |
| `enable_secrets_endpoint` | `false` (stack 03 sets `true` for Windows) |

The **origin** client is also where `stacks/04-flexcache` runs the FlexCache configuration (SSM Run
Command), so keep `enable_ssm = true` for it.

**Outputs:** `instance_id`, `private_ip`, `os`, `eice_id`, `mounts` (Linux mount points or Windows drives), `domain`, `connect_eice`, `connect_ssm`, `role_name`, `ssm_enabled`, `secrets_endpoint`.
