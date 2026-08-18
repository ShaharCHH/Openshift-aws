# Launches a real instance to prove the subnet/SG/instance-profile/SSM wiring
# actually works in this account. Defaults to an AWS-owned base AMI (always
# allowed) rather than RHCOS specifically -- AMI-ownership restrictions are a
# separate, already-solved concern (see scripts/ami-build/build-custom-ami.sh),
# not a generic launch-capability question, which is what this canary is for.
# No key_name: access is via SSM only, matching the rest of this design.

data "aws_ami" "allowed_base" {
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

resource "aws_instance" "canary" {
  ami                    = var.ami_id != null ? var.ami_id : data.aws_ami.allowed_base[0].id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_id]
  iam_instance_profile   = var.instance_profile_name
  tags                   = { Name = "${var.name_prefix}-ec2-canary" }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }
}
