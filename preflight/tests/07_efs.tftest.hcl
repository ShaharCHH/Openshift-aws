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

# EFS is the entire storage design's foundation (docs/architecture.md): no
# CSI driver can ever work here, and credentialsMode: Manual rules out every
# other AWS-credentialed alternative. If EFS is also blocked in a new
# account, that account has no storage answer at all -- this has to surface
# here in Phase 0, not partway through Phase 8 of a live bring-up, which is
# how this project found out the first time.
run "create_efs_and_mount_target" {
  command = apply

  module {
    source = "./fixtures/efs"
  }

  providers = {
    aws = aws
  }

  variables {
    vpc_id      = var.existing_vpc_id
    subnet_id   = var.existing_private_subnet_id
    name_prefix = var.name_prefix
  }

  assert {
    condition     = length(output.file_system_id) > 0
    error_message = "failed to create the EFS filesystem this account's entire storage design depends on"
  }

  assert {
    condition     = length(output.mount_target_ips) == 1
    error_message = "expected exactly one EFS mount target (one subnet was passed in) -- got a different count"
  }
}
