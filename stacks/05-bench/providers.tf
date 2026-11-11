terraform {
  # No AWS provider: the module sends SSM commands with the AWS CLI on the operator machine,
  # using the same AWS_PROFILE as the other stacks.
  required_version = ">= 1.10"
}
