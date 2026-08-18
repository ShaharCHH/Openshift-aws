variable "name_prefix" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  type        = string
  description = <<-EOT
    Pinned private IP for the bastion (e.g. cidrhost(subnet_cidr, 10),
    computed by the caller). Deliberately static rather than
    discovered-at-boot-via-IMDS: CoreDNS's zonefile, the ignition pointer
    URLs, and HAProxy's own identity all need to reference this instance's
    address, and pinning it via Terraform avoids any chicken-and-egg between
    "what's my IP" and "render my own config" at boot time.
  EOT
}

variable "sg_id" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "bastion_role_name" {
  type        = string
  description = "IAM role name backing instance_profile_name -- this module attaches its own S3 read policy to it directly."
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_id" {
  type        = string
  default     = null
  description = "Defaults to the latest AWS-owned Amazon Linux 2023 AMI when null. The bastion runs Docker containers only -- it has no need to be RHCOS."
}

variable "cluster_name" {
  type = string
}

variable "base_domain" {
  type = string
}

variable "upstream_dns" {
  type        = string
  description = "Resolver for non-cluster DNS queries -- typically cidrhost(vpc_cidr, 2), the VPC's built-in Route 53 Resolver."
}

variable "ignition_bucket_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "oc_version" {
  type        = string
  default     = "stable-4.22"
  description = <<-EOT
    Release channel or exact version directory under
    mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/ to install the
    oc client from (e.g. "stable-4.22", "latest", "4.22.9"). Should track the
    cluster's own version. Installed best-effort -- a failed download logs a
    warning rather than aborting the bastion's setup, since oc is an operator
    convenience and everything else in that script is load-bearing.
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}
