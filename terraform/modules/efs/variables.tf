variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "One mount target (an ENI with an IP) is created per subnet. Nodes connect to the IP in their own subnet."
}

variable "client_security_group_ids" {
  type        = map(string)
  description = <<-EOT
    Security groups permitted to mount the filesystem, keyed by a label used in
    the rule description (e.g. { master = sg-..., worker = sg-... }). Referenced
    by group rather than CIDR on purpose: this subnet is shared with other
    teams' workloads, and a CIDR rule would expose the filesystem to all of them.
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}
