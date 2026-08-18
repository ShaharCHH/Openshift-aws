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

run "create_eni" {
  command = apply

  module {
    source = "./fixtures/eni"
  }

  providers = {
    aws = aws
  }

  variables {
    subnet_id   = var.existing_private_subnet_id
    sg_id       = run.create_sg.bastion_sg_id
    name_prefix = var.name_prefix
  }

  assert {
    condition     = output.private_ip != ""
    error_message = "ENI did not receive a private IP in the target subnet"
  }
}
