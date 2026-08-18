variable "create_vpc" {
  type        = bool
  default     = false
  description = <<-EOT
    false (default) — look up an existing client-provided VPC/subnet via
    existing_vpc_id/existing_private_subnet_ids. true — create a new VPC and
    private subnet(s) instead, for clients whose account isn't restricted the
    way this design was originally built for.

    The create=true path is deliberately minimal: VPC + private subnets only,
    no IGW/NAT/public subnet. This design never puts a public IP on anything
    (see the bastion module), so nothing it creates needs one — but that also
    means a client using create_vpc=true is responsible for their own
    internet egress path (a NAT Gateway, a transit gateway, etc.) if the
    bastion's S3 pull needs one. Verify with the preflight suite's
    06_internet_egress canary either way.
  EOT
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to created resource names/tags"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged onto every resource this module creates"
}

# ---- create_vpc = true ----

variable "vpc_cidr" {
  type        = string
  default     = null
  description = "CIDR for the new VPC. Required if create_vpc = true."
}

variable "availability_zones" {
  type        = list(string)
  default     = []
  description = "AZs to create one private subnet in each. Required (non-empty) if create_vpc = true."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = []
  description = "One CIDR per entry in availability_zones. Required if create_vpc = true."
}

# ---- create_vpc = false ----

variable "existing_vpc_id" {
  type        = string
  default     = null
  description = "Required if create_vpc = false."
}

variable "existing_private_subnet_ids" {
  type        = list(string)
  default     = []
  description = "Required (non-empty) if create_vpc = false."
}
