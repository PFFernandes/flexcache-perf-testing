variable "name" {
  description = "Prefix for the IAM policies, e.g. pedro-flexcache-perf."
  type        = string
}

variable "lab" {
  description = "Lab name used in the results paths and as the bench.lab attribute, e.g. pedro-flexcache-perf."
  type        = string
}

variable "clients" {
  description = "Linux clients keyed by side. bucket = the package bucket of the client's own region."
  type = map(object({
    region        = string
    instance_id   = string
    role_name     = string
    bucket        = string
    bucket_arn    = string
    bucket_region = string
    ping_targets  = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for side, c in var.clients : c.bucket_region == c.region])
    error_message = "Each client must read the package from the bucket of its own region (it reaches S3 only through its region's gateway endpoint)."
  }
}

variable "results" {
  description = "The results volume (modules/12-bench-results-volume) and how the clients mount it."
  type = object({
    volume_id     = string
    volume_name   = string
    side          = string # origin | cache: which file system holds it
    nfs_ip        = string # NFS IP of that file system's SVM
    junction_path = string
    mount_point   = optional(string, "/mnt/fsxn/vol_bench")
    nfs_options   = optional(string, "vers=3,nconnect=4,hard,timeo=600,retrans=2,rsize=1048576,wsize=1048576")
  })
}

variable "cloudwatch_namespace" {
  description = "CloudWatch namespace the clients push their test metrics to after each test (modules/13-bench-cloudwatch gives them the endpoint and permission). null = no push."
  type        = string
  default     = null
}

variable "lab_info" {
  description = "Lab description written to labs/<lab>/lab.json on the results volume."
  type        = any
  default     = {}
}

# --- collector -----------------------------------------------------------------------

variable "collector_version" {
  description = "OpenTelemetry Collector Contrib release (github.com/open-telemetry/opentelemetry-collector-releases)."
  type        = string
  default     = "0.165.0"
}

variable "collector_sha256" {
  description = "SHA-256 of otelcol-contrib_<version>_linux_<arch>.rpm, from the release's .sha256 files. Change together with collector_version."
  type        = map(string)
  default = {
    amd64 = "f045845995709932dcc2952b86a9046320f6ec3c8b8615dc6f7a39931d92db94"
    arm64 = "c388cc97c36d689d77fe085b4dd5601bf6ff92bf963c67eb8596d580ad72c62a"
  }
}

variable "collector_architectures" {
  description = "Packages to stage: amd64 for x86_64 clients (t3, c6in...), arm64 for Graviton. ~118 MB each per bucket."
  type        = list(string)
  default     = ["amd64"]

  validation {
    condition     = length(var.collector_architectures) > 0 && alltrue([for a in var.collector_architectures : contains(["amd64", "arm64"], a)])
    error_message = "collector_architectures must list amd64 and/or arm64."
  }
}

variable "interval_s" {
  description = "Seconds between host-metric and NFS/ENA samples."
  type        = number
  default     = 5

  validation {
    condition     = var.interval_s >= 1 && var.interval_s <= 60
    error_message = "interval_s must be between 1 and 60."
  }
}

variable "ping_interval_s" {
  description = "Seconds between ping rounds."
  type        = number
  default     = 10
}

variable "flush_s" {
  description = "Seconds the collector batches data before writing it to the results volume."
  type        = number
  default     = 10
}

variable "staging_dir" {
  description = "Local folder on each client where results are written during a test, before bench-results-sync copies them to the results volume."
  type        = string
  default     = "/var/lib/bench/staging"
}

variable "rotate_mib" {
  description = "The collector starts a new metrics-<time>.json after this many MiB."
  type        = number
  default     = 50
}

variable "local_buffer_mib" {
  description = "Local disk the collector may use for telemetry not yet copied to the results volume. Beyond it the oldest files are dropped (the root volume is small)."
  type        = number
  default     = 2048
}

variable "memory_limit_mib" {
  description = "Memory limit of the collector (memory_limiter processor)."
  type        = number
  default     = 256
}
