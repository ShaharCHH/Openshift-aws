# The bastion instance + day-0 userdata only. It does NOT own ongoing
# haproxy backend-list changes -- that's modules/haproxy-config, invoked
# repeatedly across the cluster lifecycle without ever touching this
# resource. See docs/architecture.md.

data "aws_ami" "al2023" {
  count       = var.ami_id == null ? 1 : 0
  owners      = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Ignition's/haproxy-config's own reads are anonymous-from-the-bastion's-
# perspective in the sense that RHCOS nodes never touch S3 directly -- but
# the bastion itself pulls from S3 using this normal, IAM-authenticated
# policy. See docs/architecture.md's "How Ignition works" for the full
# reasoning (this replaced an S3-Gateway-VPC-Endpoint design that turned out
# to depend on an SCP-blocked API call).
data "aws_iam_policy_document" "s3_read" {
  statement {
    sid     = "ReadIgnitionAndHaproxyConfig"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.ignition_bucket_name}/ignition/*",
      "arn:aws:s3:::${var.ignition_bucket_name}/haproxy/*",
    ]
  }

  statement {
    sid       = "ListIgnitionBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.ignition_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["ignition/*", "haproxy/*"]
    }
  }
}

resource "aws_iam_role_policy" "s3_read" {
  name   = "${var.name_prefix}-bastion-s3-read"
  role   = var.bastion_role_name
  policy = data.aws_iam_policy_document.s3_read.json
}

locals {
  # Rendered once with empty backends for the initial boot; modules/haproxy-config
  # renders the same template with real backends on every later update and
  # pushes it via SSM -- this module never touches haproxy.cfg again after
  # this first boot.
  initial_haproxy_cfg = templatefile("${path.module}/../../templates/haproxy.cfg.tpl", {
    api_backends     = []
    mcs_backends     = []
    ingress_backends = []
  })

  user_data = templatefile("${path.module}/../../templates/bastion-userdata.sh.tpl", {
    cluster_name         = var.cluster_name
    base_domain          = var.base_domain
    private_ip           = var.private_ip
    upstream_dns         = var.upstream_dns
    ignition_bucket_name = var.ignition_bucket_name
    aws_region           = var.aws_region
    haproxy_cfg          = local.initial_haproxy_cfg
  })
}

resource "aws_instance" "bastion" {
  ami                    = var.ami_id != null ? var.ami_id : data.aws_ami.al2023[0].id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = [var.sg_id]
  iam_instance_profile   = var.instance_profile_name
  user_data              = local.user_data
  tags                   = merge(var.tags, { Name = "${var.name_prefix}-bastion" })

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }
}
