variable "name_prefix" {
  type        = string
  description = "Prefix applied to role/instance-profile names and Name tags"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged onto every role and instance profile"
}
