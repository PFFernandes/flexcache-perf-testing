variable "clients" {
  description = "Linux EC2 clients to deploy to, keyed by side (origin, cache). Their SSM agent must be online."
  type = map(object({
    region      = string
    instance_id = string
  }))

  validation {
    condition     = alltrue([for k in keys(var.clients) : contains(["origin", "cache"], k)])
    error_message = "clients keys must be origin and/or cache."
  }
}

variable "source_root" {
  description = "Absolute path of the repository root on the machine running Terraform."
  type        = string
}

variable "source_dirs" {
  description = "Folders under source_root that make up the bench."
  type        = list(string)
  default     = ["bench", "profiles"]
}

variable "install_packages" {
  description = "Extra Amazon Linux packages to install with dnf, e.g. [\"python3-pyyaml\"]. A failure is reported, not fatal."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.install_packages : can(regex("^[A-Za-z0-9._+-]+$", p))])
    error_message = "install_packages entries must be plain package names."
  }
}

variable "run_tests" {
  description = "Run the bench's own tests on each client after deploying (offline, a few seconds)."
  type        = bool
  default     = true
}
