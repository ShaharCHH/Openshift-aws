variable "ami_id" {
  type        = string
  default     = null
  description = <<-EOT
    Defaults to the latest AWS-owned Amazon Linux 2023 AMI when null. This
    canary tests generic launch/SSM capability (subnet/SG/instance-profile
    wiring), which is a separate concern from "is a specific third-party AMI
    launchable" -- some accounts' SCPs block RunInstances for AMIs they don't
    own (confirmed against Red Hat's public RHCOS AMI in the account this was
    built against), which has nothing to do with whether launching in general
    works. Pass an explicit ami_id only if you specifically need to test that.
  EOT
}

variable "subnet_id" {
  type = string
}

variable "sg_id" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.medium" # canary sizing only — not representative of real node sizing
}
