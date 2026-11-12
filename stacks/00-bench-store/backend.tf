terraform {
  # Local state: terraform.tfstate is written next to this file (git-ignored).
  # Later stacks read it through terraform_remote_state with backend = "local".
  # Moving to S3 later = replace this block with backend "s3" { ... } and run
  # `terraform init -migrate-state`.
  backend "local" {}
}
