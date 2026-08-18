# One EC2 instance role + instance profile per cluster role. Each gets
# AmazonSSMManagedInstanceCore so every node type is reachable via SSM
# Session Manager / send-command — the same no-EIP, no-bastion-SSH access
# path used everywhere else in this design.
#
# NOTE: iam:PassRole on these specific role ARNs is a permission the CALLER
# (whoever runs `terraform apply`) needs on their own identity/SCP — it is
# not something this module grants, since these are EC2-launch instance
# roles, not roles anyone assumes directly.

locals {
  roles = ["bastion", "bootstrap", "master", "worker"]
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = toset(local.roles)

  name               = "${var.name_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = aws_iam_role.this

  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The in-cluster AWS cloud-controller-manager can't initialize any node
# without this -- every node keeps its automatic
# node.cloudprovider.kubernetes.io/uninitialized taint forever, which the
# network operator (and everything downstream of it, including CNI) refuses
# to schedule onto. Confirmed for real: aws-cloud-controller-manager crashed
# in a loop with a real UnauthorizedOperation on ec2:DescribeInstances,
# stalling the whole cluster bootstrap indefinitely. Scoped to master only
# (that's the role the crash loop was actually running as) and to this one
# confirmed-needed action, not the default installer's broad ec2:*
# wildcard -- broader cloud-controller-manager features (ELB, EBS
# provisioning) aren't exercised by this design (own HAProxy for ingress,
# no LoadBalancer-type Services) and are deliberately still absent.
data "aws_iam_policy_document" "master_cloud_provider" {
  statement {
    # Read-only EC2 describes for the in-cluster cloud provider. The first
    # three were each found the hard way, one crash-loop cycle at a time,
    # from a real UnauthorizedOperation in the operator's own logs:
    # DescribeInstances (node identification), DescribeAvailabilityZones
    # (node_controller's per-node metadata sync), DescribeSubnets (the
    # service controller's subnet lookup).
    #
    # The rest are granted pre-emptively rather than continuing that
    # pattern. Three sequential discoveries, each costing a restart cycle to
    # surface, is enough evidence that the cloud provider's read path is
    # wider than any single error reveals. These are all non-mutating
    # describes, so granting them adds no ability to change anything --
    # unlike the installer's default ec2:* wildcard, which would also carry
    # create/delete and is still deliberately not used here.
    #
    # Note what is still NOT here: anything under elasticloadbalancing:*.
    # That is not an oversight waiting on the next error -- ELB creation is
    # SCP-blocked outright (docs/scp-blockers.md row 4), which is why
    # ingress runs through HAProxy on the bastion with the default
    # IngressController pinned to HostNetwork (see
    # scripts/ignition/generate-ignition.sh). Anything here asking for a
    # LoadBalancer-type Service is a misconfiguration to fix at its source,
    # not a missing permission to grant.
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeSubnets",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "master_cloud_provider" {
  name   = "${var.name_prefix}-master-cloud-provider"
  role   = aws_iam_role.this["master"].name
  policy = data.aws_iam_policy_document.master_cloud_provider.json
}

resource "aws_iam_instance_profile" "this" {
  for_each = aws_iam_role.this

  name = "${var.name_prefix}-${each.key}"
  role = each.value.name
  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}
