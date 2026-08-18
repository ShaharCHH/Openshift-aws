variable "aws_region" {
  type = string
}
variable "name_prefix" {
  type = string
}

provider "aws" {
  region = var.aws_region
}

run "create_iam" {
  command = apply

  module {
    source = "../terraform/modules/iam"
  }

  providers = {
    aws = aws
  }

  variables {
    name_prefix = var.name_prefix
  }

  assert {
    condition     = length(output.instance_profile_names) == 4
    error_message = "expected 4 instance profiles (bastion, bootstrap, master, worker)"
  }
}
