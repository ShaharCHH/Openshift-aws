resource "aws_network_interface" "canary" {
  subnet_id       = var.subnet_id
  security_groups = [var.sg_id]
  tags            = { Name = "${var.name_prefix}-eni" }
}
