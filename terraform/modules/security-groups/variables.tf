variable "vpc_id" {
  type        = string
  description = "VPC to create the security groups in"
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to security group names and Name tags"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged onto every security group"
}
