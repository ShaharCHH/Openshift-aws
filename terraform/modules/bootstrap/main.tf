# The temporary bootstrap node. Gated by var.bootstrap_enabled at the root
# level so a later apply with that flag flipped cleanly destroys it once
# `openshift-install wait-for bootstrap-complete` returns -- see
# docs/runbook.md's Phase 6.

locals {
  # Same real-root network keyfile the masters get. Bootstrap is short-lived and
  # may never reboot, but it cannot be covered the way masters could be (via a
  # MachineConfig) -- it *is* the Machine Config Server, so it never fetches from
  # one. Delivering it here keeps both roles on a single mechanism.
  node_network_keyfile = templatefile("${path.module}/../../templates/node-network.nmconnection.tpl", {
    bastion_private_ip = var.bastion_private_ip
  })

  pointer_ignition = jsonencode({
    ignition = {
      version = "3.2.0"
      config = {
        merge = [
          { source = "http://${var.bastion_private_ip}:8080/ignition/bootstrap.ign" }
        ]
      }
    }
    storage = {
      files = [
        {
          path      = "/etc/NetworkManager/system-connections/default-dhcp.nmconnection"
          mode      = 384 # 0600 -- NetworkManager silently ignores world-readable keyfiles
          overwrite = true
          contents = {
            source = "data:text/plain;base64,${base64encode(local.node_network_keyfile)}"
          }
        }
      ]
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
