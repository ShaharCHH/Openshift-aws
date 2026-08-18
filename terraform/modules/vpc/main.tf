# create_vpc = true: new VPC + one private subnet per AZ, nothing else.
# No IGW/NAT/public subnet — this whole design never assigns a public IP to
# anything (see modules/bastion), so nothing created here needs one. A
# client using this path is responsible for their own internet egress if the
# bastion's S3 pull needs one; verify with preflight's 06_internet_egress
# canary regardless of which path is used.

resource "aws_vpc" "this" {
  count = var.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_subnet" "private" {
  count = var.create_vpc ? length(var.availability_zones) : 0

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}" })
}

# create_vpc = false: look up what the client already has.

data "aws_vpc" "existing" {
  count = var.create_vpc ? 0 : 1
  id    = var.existing_vpc_id
}

data "aws_subnet" "existing_private" {
  count = var.create_vpc ? 0 : length(var.existing_private_subnet_ids)
  id    = var.existing_private_subnet_ids[count.index]
}
