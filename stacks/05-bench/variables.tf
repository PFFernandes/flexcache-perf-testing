# --- common (from ../../common.tfvars) --------------------------------------

variable "project" {
  type = string
}

variable "creator" {
  description = "Creator tag on every AWS resource, and the start of every Name (<creator>-<project>-...)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.creator))
    error_message = "creator is used in resource names: lowercase letters, digits and hyphens only, e.g. \"pedro\"."
  }
}

variable "origin_region" {
  type = string
}

variable "cache_region" {
  type = string
}

# origin_azs / cache_azs are only used by 01-landing-zone (they shape the subnets);
# declared here so the shared common.tfvars passes without warnings.

variable "deploy_origin" {
  description = "Deploy the Origin side: Network Origin (01-landing-zone) and FSx for ONTAP Origin (02-fsxn)."
  type        = bool
  default     = true
}

variable "deploy_cache" {
  description = "Deploy the Cache side: Network Cache (01-landing-zone) and FSx for ONTAP Cache (02-fsxn)."
  type        = bool
  default     = true

  validation {
    condition     = var.deploy_origin || var.deploy_cache
    error_message = "Nothing to deploy: set deploy_origin and/or deploy_cache to true in common.tfvars."
  }
}

variable "protocol" {
  description = "File protocol of the lab: nfs (default, Linux clients) or smb (AWS Managed AD, Windows clients, shares Origin and Cache)."
  type        = string
  default     = "nfs"

  validation {
    condition     = contains(["nfs", "smb"], var.protocol)
    error_message = "protocol must be \"nfs\" or \"smb\"."
  }

  validation {
    condition     = var.protocol == "nfs" || var.deploy_origin
    error_message = "protocol = \"smb\" needs deploy_origin = true: the Managed AD lives in the origin VPC."
  }
}

variable "origin_azs" {
  description = "AZ letters for the origin side, appended to origin_region (\"a\" = <region>a). One private subnet per AZ. Single-AZ FSxN uses the first, Multi-AZ needs two, e.g. [\"a\", \"b\"]."
  type        = list(string)
  default     = ["a"]

  validation {
    condition     = length(var.origin_azs) >= 1 && alltrue([for s in var.origin_azs : can(regex("^[a-z]$", s))])
    error_message = "origin_azs must be a non-empty list of AZ letters, e.g. [\"a\"] or [\"a\", \"b\"]."
  }
}

variable "cache_azs" {
  description = "AZ letters for the cache side, appended to cache_region. Same rules as origin_azs."
  type        = list(string)
  default     = ["a"]

  validation {
    condition     = length(var.cache_azs) >= 1 && alltrue([for s in var.cache_azs : can(regex("^[a-z]$", s))])
    error_message = "cache_azs must be a non-empty list of AZ letters, e.g. [\"a\"] or [\"a\", \"b\"]."
  }
}

# --- test bench ---------------------------------------------------------------------

variable "bench_clients" {
  description = "Clients that get the bench: origin and/or cache. A side whose client isn't in the 03-ec2 state is skipped."
  type        = list(string)
  default     = ["origin", "cache"]

  validation {
    condition     = length(var.bench_clients) > 0 && alltrue([for s in var.bench_clients : contains(["origin", "cache"], s)])
    error_message = "bench_clients must list origin and/or cache."
  }
}

variable "install_packages" {
  description = "Extra Amazon Linux packages for the clients, e.g. [\"python3-pyyaml\"] for .yaml dataset specs."
  type        = list(string)
  default     = []
}

variable "run_tests" {
  description = "Run the bench's own tests on each client after deploying."
  type        = bool
  default     = true
}

# --- telemetry -----------------------------------------------------------------------

variable "telemetry" {
  description = "Create the results volume and install the OpenTelemetry Collector and bench-probe on the clients, writing to it. Needs 02-fsxn and stacks/00-bench-store (package delivery)."
  type        = bool
  default     = true
}

variable "telemetry_interval_s" {
  description = "Seconds between host-metric and NFS/ENA samples on the clients."
  type        = number
  default     = 5
}

variable "ping_interval_s" {
  description = "Seconds between ping rounds to the file systems' NFS IPs."
  type        = number
  default     = 10
}

variable "collector_version" {
  description = "OpenTelemetry Collector Contrib release. Change together with collector_sha256."
  type        = string
  default     = "0.165.0"
}

variable "collector_sha256" {
  description = "SHA-256 of otelcol-contrib_<version>_linux_<arch>.rpm (the release's .sha256 files)."
  type        = map(string)
  default = {
    amd64 = "f045845995709932dcc2952b86a9046320f6ec3c8b8615dc6f7a39931d92db94"
    arm64 = "c388cc97c36d689d77fe085b4dd5601bf6ff92bf963c67eb8596d580ad72c62a"
  }
}

variable "collector_architectures" {
  description = "Collector packages to stage: amd64 for x86_64 instance types, arm64 for Graviton (architecture in stacks/03-ec2)."
  type        = list(string)
  default     = ["amd64"]
}

variable "results_volume" {
  description = "The results volume: which file system holds it (origin or cache), its name and size. FSx keeps a final backup when it's deleted."
  type = object({
    side     = optional(string, "origin")
    name     = optional(string, "vol_bench")
    size_gib = optional(number, 100)
  })
  default = {}

  validation {
    condition     = contains(["origin", "cache"], var.results_volume.side)
    error_message = "results_volume.side must be origin or cache."
  }
}

variable "cloudwatch" {
  description = "With telemetry: a CloudWatch endpoint in each client VPC, permission to push to the FlexCacheBench namespace, and the lab's CloudWatch dashboard. The clients push each test's metrics after the test."
  type        = bool
  default     = true
}
