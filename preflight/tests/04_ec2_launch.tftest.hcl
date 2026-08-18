variable "aws_region" {
  type = string
}
variable "existing_vpc_id" {
  type = string
}
variable "existing_private_subnet_id" {
  type = string
}
variable "name_prefix" {
  type = string
}

provider "aws" {
  region = var.aws_region
}

run "create_sg" {
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
}

run "launch_canary_instance" {
  command = apply

  module {
    source = "./fixtures/ec2-canary"
  }

  providers = {
    aws = aws
  }

  variables {
    subnet_id             = var.existing_private_subnet_id
    sg_id                 = run.create_sg.master_sg_id
    instance_profile_name = run.create_iam.instance_profile_names["master"]
    name_prefix           = var.name_prefix
  }

  assert {
    condition     = output.instance_state == "running"
    error_message = "canary instance (AWS-owned base AMI) failed to reach running state"
  }
}
