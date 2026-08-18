output "vpc_id" {
  value = var.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
}

output "vpc_cidr" {
  value = var.create_vpc ? aws_vpc.this[0].cidr_block : data.aws_vpc.existing[0].cidr_block
}

output "private_subnet_ids" {
  value = var.create_vpc ? aws_subnet.private[*].id : var.existing_private_subnet_ids
}

output "private_subnet_azs" {
  value = var.create_vpc ? aws_subnet.private[*].availability_zone : data.aws_subnet.existing_private[*].availability_zone
}

output "private_subnet_cidrs" {
  value = var.create_vpc ? aws_subnet.private[*].cidr_block : data.aws_subnet.existing_private[*].cidr_block
}
