# EFS as the cluster's storage backend, used as a plain NFS server rather than
# through the AWS EFS CSI driver.
#
# WHY NOT THE CSI DRIVER: every CSI driver on AWS wants its own cloud
# credential, and this cluster cannot give one to anything. install-config sets
# credentialsMode: Manual (an SSO session cannot supply long-lived keys), so the
# Cloud Credential Operator mints nothing, and both ways of satisfying that by
# hand are hard-denied -- probed for real:
#
#   iam:CreateUser                    explicit deny, policy p-cf140vwn
#   iam:CreateOpenIDConnectProvider   explicit deny, policy p-77bk5ceo
#
# The instance profile is not a way out either: the EBS CSI *controller* runs on
# the pod network (hostNetwork=false), and OVN-Kubernetes does not forward pod
# traffic to 169.254.169.254, so it can never reach IMDS to borrow the node's
# identity. Confirmed on this cluster -- from a node, IMDS returns
# "horizon-horizon-master"; from a pod, no response at all, with the hop limit
# raised to 2 and no firewall rule on the node to explain it.
#
# EFS sidesteps all of that because it speaks NFSv4.1. Nothing in the cluster
# has to call AWS: static PVs need no driver, and dynamic provisioning is done
# by nfs-subdir-external-provisioner, which only ever performs NFS operations.
#
# That EFS is available here at all was worth checking rather than assuming --
# it is the first capability probed in this account that turned out NOT to be
# blocked:
#   elasticfilesystem:CreateFileSystem    ALLOWED
#   elasticfilesystem:CreateMountTarget   ALLOWED (ENI placed in the private subnet)

resource "aws_efs_file_system" "this" {
  creation_token = var.name_prefix
  encrypted      = true # account has EBS/EFS encryption by default; being explicit

  # Bursting suits a general-purpose cluster and costs nothing when idle;
  # provisioned throughput bills whether or not anything is reading.
  throughput_mode  = "bursting"
  performance_mode = "generalPurpose"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-efs" })
}

# Its own group rather than reusing the node SGs: this controls who may reach
# the filesystem, which is a different question from what the nodes expose.
resource "aws_security_group" "efs" {
  name_prefix = "${var.name_prefix}-efs-"
  description = "NFS access to the cluster EFS filesystem"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

# 2049 is NFS. Referenced by security group, not CIDR, so only this
# deployment's own nodes can mount it -- the subnet is shared with other teams.
resource "aws_vpc_security_group_ingress_rule" "nfs" {
  for_each = var.client_security_group_ids

  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  description                  = "NFS from ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.efs.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "allow all outbound"
}

# One mount target per subnet. A mount target is an ENI holding an IP in that
# subnet -- that IP is what nodes actually connect to, and it is why EFS works
# here without any VPC endpoint (ec2:CreateVpcEndpoint being SCP-denied).
resource "aws_efs_mount_target" "this" {
  for_each = toset(var.subnet_ids)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}
