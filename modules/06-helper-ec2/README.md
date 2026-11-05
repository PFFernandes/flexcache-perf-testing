# modules/06-helper-ec2 — helper EC2 (network hop for stack 04)

A small private Amazon Linux 2023 instance plus an **EC2 Instance Connect Endpoint (EICE)** in the
same subnet. It only forwards TCP: `scripts/ontap-tunnel.sh` opens an SSH tunnel from your Mac
through the EICE to the helper, with port forwards to both FSx for ONTAP management IPs. Stack
`04-flexcache` (ONTAP provider) then talks to `localhost:8443` / `localhost:9443`. Called by
`stacks/03-helper`.

The helper runs no ONTAP commands. Cluster peering and FlexCache traffic go **cluster to cluster**
over the intercluster LIFs and the VPC peering, never through it.

- **No internet:** no public IP, no IGW, no NAT. EICE is free and only allows TCP 22.
- **Security groups:** EICE → helper on 22 only; helper egress open (reaches both management IPs; the
  FSx for ONTAP security groups already allow the origin VPC CIDR).
- **Access:** EC2 Instance Connect pushes a 60-second key per session, so there is no key pair.

**Tags:** every resource gets the `Creator` tag and a `Name` starting with `<creator>-<project>`
(`pedro-flexcache-perf-helper`, `...-helper-eice`, `...-helper-sg`, `...-helper-root`).

| Input | Default |
|---|---|
| `name`, `vpc_id`, `subnet_id` | required |
| `instance_type` | `t4g.small` |
| `architecture` | `arm64` (match the instance type) |
| `ami_id` | latest AL2023 |
| `root_volume_gib` | `8` |

**Outputs:** `instance_id`, `private_ip`, `eice_id`, `os_user`.
