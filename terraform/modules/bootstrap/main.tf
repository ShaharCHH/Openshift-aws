# The temporary bootstrap node. Gated by var.bootstrap_enabled at the root
# level so a later apply with that flag flipped cleanly destroys it once
# `openshift-install wait-for bootstrap-complete` returns -- see
# docs/runbook.md's Phase 6.

locals {
  pointer_ignition = jsonencode({
    ignition = {
      version = "3.2.0"
      config = {
        merge = [
          { source = "http://${var.bastion_private_ip}:8080/ignition/bootstrap.ign" }
        ]
      }
    }
  })
}

resource "aws_instance" "bootstrap" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_id]
  iam_instance_profile   = var.instance_profile_name
  user_data              = local.pointer_ignition

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-bootstrap" })
}
