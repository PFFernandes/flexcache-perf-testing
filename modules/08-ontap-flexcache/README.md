# modules/08-ontap-flexcache — FlexCache, configured on the origin EC2 client

Creates the FlexCache relationship between the FSx for ONTAP Origin and Cache. Called by
`stacks/04-flexcache`.

The AWS FSx API has no cluster peering or FlexCache calls, so they go through the **ONTAP REST
API** on the two management IPs, which are private. This module doesn't reach them from the operator machine:
it runs the configuration **on the origin EC2 client** (`modules/07-ec2-client`), which sees the
Origin management IP in its own VPC and the Cache one over the peering.

| Step | Where | What |
|---|---|---|
| 1 | AWS | Secrets Manager interface endpoint in the origin VPC (`create_secrets_endpoint`), HTTPS from the origin VPC only |
| 2 | AWS | inline policy on the origin client's role: `secretsmanager:GetSecretValue` on the fsxadmin secret only |
| 3 | operator machine | `files/ssm-run.sh` (Terraform `local-exec`) waits for the client to be online in SSM, sends the script with SSM Run Command and prints its log: `files/flexcache.py` with `AWS-RunShellScript` (Linux), `files/flexcache.ps1` with `AWS-RunPowerShellScript` (Windows) |
| 4 | origin client | `create`: reads the fsxadmin password from Secrets Manager, then cluster peer → SVM peer → FlexCache volume → (SMB) shares |
| – | destroy | `delete`: (SMB) shares → FlexCache (unmount, offline, delete) → SVM peer → cluster peer |

What `flexcache.py` does on ONTAP:
- **Cluster peer** Origin ⇄ Cache over the intercluster IPs, with a one-time passphrase generated on
  the client. If only one side exists (an interrupted run), it is removed and both are recreated.
- **SVM peer** `svm-cache` → `svm-origin` with the `flexcache` application, accepted on the Origin.
- **FlexCache volume** on `svm-cache`, origin `vol_origin` on `svm-origin`, size / junction path /
  aggregates from the inputs (`POST /api/storage/flexcache/flexcaches`).
- **SMB shares** (`protocol = "smb"`, `flexcache.ps1` only): `origin` on `svm-origin` → the origin
  junction path, `cache` on `svm-cache` → the FlexCache junction path (`POST /api/protocols/cifs/shares`),
  with SMB encryption required. Names from `share_names`. On Windows the script is saved in `C:\fsxn`
  (SYSTEM and Administrators only), and the certificate check is skipped only for the two ONTAP
  management IPs.

Every step checks what already exists first, so re-running is safe. The password is never part of
the SSM command or the Terraform state of this stack; the config sent to the client only holds IPs,
names and the secret ARN. Any change to the inputs deletes and recreates the setup
(`terraform_data` with `triggers_replace`). The SMB fields are only added to that config for SMB, so
an existing NFS setup keeps its hash and isn't rebuilt by this module's upgrade.

Requirements: the origin client has SSM (`enable_ssm = true` in `stacks/03-ec2`), and `aws`, `bash`
and `gzip` on the operator machine. The Linux client uses only Python 3 and the AWS CLI, both preinstalled on
Amazon Linux 2023. The Windows client uses Windows PowerShell 5.1 and AWS Tools for PowerShell,
both preinstalled on the Windows AMIs.

**Tags:** the AWS resources get the `Creator` tag and a `Name` starting with `<creator>-<project>`
(`pedro-flexcache-perf-flexcache-secretsmanager-endpoint`, `...-sg`). ONTAP objects can't carry AWS
tags.

| Input | Default |
|---|---|
| `name`, `client_instance_id`, `client_region`, `client_role_name` | required |
| `vpc_id`, `vpc_cidr`, `subnet_id` (origin VPC) | required |
| `fsxadmin_secret_arn`, `fsxadmin_secret_region` | required |
| `origin` = `{ management_ip, intercluster_ips, svm_name, volume_name, junction_path }` | required (`junction_path` default `/vol_origin`) |
| `client_os` | `linux` (`windows` runs `flexcache.ps1`) |
| `protocol` | `nfs` (`smb` needs `client_os = "windows"`) |
| `share_names` | `{ origin = "origin", cache = "cache" }` |
| `cache` = `{ management_ip, intercluster_ips, svm_name }` | required |
| `flexcache_name` / `flexcache_size_gib` / `flexcache_junction_path` | `vol_cache` / `500` / `/vol_cache` |
| `aggregates` | `["aggr1"]` |
| `create_secrets_endpoint` | `true` |

**Outputs:** `flexcache_name`, `flexcache_junction_path`, `secrets_endpoint_id`, `shares` (SMB, else null).
