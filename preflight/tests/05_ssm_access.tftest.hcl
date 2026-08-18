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

run "launch_instance" {
  command = apply

  module {
    source = "./fixtures/ec2-canary"
  }

  providers = {
    aws = aws
  }

  variables {
    subnet_id             = var.existing_private_subnet_id
    sg_id                 = run.create_sg.bastion_sg_id
    instance_profile_name = run.create_iam.instance_profile_names["bastion"]
    name_prefix           = var.name_prefix
  }
}

# fixtures/ssm-check only uses a `data "external"` resource (the hashicorp/external
# provider, auto-required, no configuration needed) — no aws provider passthrough
# required here.
run "ssm_reachability" {
  command = apply

  module {
    source = "./fixtures/ssm-check"
  }

  variables {
    instance_id     = run.launch_instance.instance_id
    timeout_seconds = 240
  }

  assert {
    condition     = output.status == "Success"
    error_message = "SSM send-command never reported Success — agent registration or IAM SSM policy is broken"
  }
}
