# NOTE on boilerplate: every run block below uses an explicit `module {}`
# source (a "secondary module" in terraform-test terms, since we're testing
# the real production modules, not a root main.tf). Secondary modules don't
# automatically inherit the file's provider config — each such run block
# needs `providers = { aws = aws }`, and the provider itself must be
# declared directly in this file (not just in ../providers.tf) with its own
# `variable` redeclarations. This is repeated per test file because
# `terraform test` files can't share declarations.

variable "aws_region" {
  type = string
}
variable "existing_vpc_id" {
  type = string
}
variable "name_prefix" {
  type = string
}

provider "aws" {
  region = var.aws_region
}

run "create_security_groups" {
  command = apply

  module {
    source = "../terraform/modules/security-groups"
  }

  providers = {
    aws = aws
  }

  variables {
    vpc_id      = var.existing_vpc_id
    name_prefix = var.name_prefix
  }

  assert {
    condition     = output.bastion_sg_id != ""
    error_message = "bastion security group was not created"
  }

  assert {
    condition     = output.master_sg_id != output.worker_sg_id
    error_message = "master and worker security groups should be distinct"
  }
}
