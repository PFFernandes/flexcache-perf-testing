terraform {
  # No providers: terraform_data is built in, and the SSM calls are made by the AWS CLI.
  required_version = ">= 1.10"
}
