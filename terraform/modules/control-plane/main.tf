# Control-plane (master) instances. In a compact topology (masters
# schedulable, no dedicated workers -- see docs/architecture.md), these also
# carry ordinary cluster workloads and ingress traffic.
#
# The pointer ignition is built inline via jsonencode() rather than a
# separate template + wrap-ignition.sh script -- Terraform produces
# guaranteed-valid JSON natively, so there's no shell-escaping risk to
# manage for something this small.

locals {
  # Written to the real root so the node still has networking after a reboot --
  # the AMI's kernel arguments only cover the initramfs. See the template's own
  # comment, and docs/architecture.md, for the failure this prevents.
  node_network_keyfile = templatefile("${path.module}/../../templates/node-network.nmconnection.tpl", {
    bastion_private_ip = var.bastion_private_ip
  })

  pointer_ignition = jsonencode({
    ignition = {
      version = "3.2.0"
      config = {
        merge = [
          { source = "http://${var.bastion_private_ip}:8080/ignition/master.ign" }
        ]
      }
      security = {
        tls = {
          certificateAuthorities = [
            { source = var.mcs_ca_data_url }
          ]
        }
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

resource "aws_instance" "master" {
  count = var.master_count

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

  tags = merge(var.tags, { Name = "${var.name_prefix}-master-${count.index}" })
}
