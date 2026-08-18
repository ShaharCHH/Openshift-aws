variable "aws_region" {
  type        = string
  description = "Target AWS region for this account's OpenShift install"
}

variable "existing_vpc_id" {
  type        = string
  description = "VPC to run canaries in (must already exist in the target account)"
}

variable "existing_private_subnet_id" {
  type        = string
  description = "Private subnet to launch canary ENIs/instances in"
}

variable "name_prefix" {
  type        = string
  default     = "ocp-preflight"
  description = "Prefix for all canary resource names/tags — should be unique per run (run-all.sh generates one)"
}
