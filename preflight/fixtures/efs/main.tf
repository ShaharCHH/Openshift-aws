# Wraps the real production efs module and adds a throwaway "client" security
# group, so a passing canary proves the actual module -- filesystem, its own
# security group, and one mount target -- works, not a lookalike.

resource "aws_security_group" "canary_client" {
  name_prefix = "${var.name_prefix}-efs-canary-client-"
  description = "Stand-in client SG for the EFS preflight canary"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

module "efs" {
  source = "../../../terraform/modules/efs"

  name_prefix = var.name_prefix
  vpc_id      = var.vpc_id
  subnet_ids  = [var.subnet_id]

  client_security_group_ids = {
    canary = aws_security_group.canary_client.id
  }
}
