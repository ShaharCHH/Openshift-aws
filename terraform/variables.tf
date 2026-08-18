# Identity

variable "account_alias" {
  type        = string
  description = "Short label for the target client AWS account -- used in resource naming/tagging, matches the accounts/<alias>.tfvars filename."
}

variable "cluster_name" {
  type = string
}

variable "base_domain" {
  type        = string
  description = "Forms cluster_domain = \"<cluster_name>.<base_domain>\". Purely internal -- CoreDNS on the bastion resolves it, it never needs real public DNS delegation."
}

variable "aws_region" {
  type = string
}

# Networking

variable "create_vpc" {
  type        = bool
  default     = false
  description = "false (default): use the client's existing VPC/subnet. true: create a new one -- see modules/vpc for what that path does and doesn't include."
}

variable "vpc_cidr" {
  type        = string
  default     = null
  description = "Required if create_vpc = true."
}

variable "availability_zones" {
  type        = list(string)
  default     = []
  description = "Required if create_vpc = true."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = []
  description = "Required if create_vpc = true -- one entry per availability_zones."
}

variable "existing_vpc_id" {
  type        = string
  default     = null
  description = "Required if create_vpc = false."
}

variable "existing_private_subnet_id" {
  type        = string
  default     = null
  description = "Required if create_vpc = false."
}

# Sizing

variable "bastion_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "master_instance_type" {
  type    = string
  default = "m5.xlarge" # Red Hat's documented minimum for control-plane nodes
}

variable "master_root_volume_size" {
  type    = number
  default = 100 # GiB -- Red Hat's documented minimum
}

variable "master_count" {
  type    = number
  default = 3
}

# OpenShift

variable "rhcos_ami_id" {
  type        = string
  default     = null
  description = "Output of scripts/ami-build/build-custom-ami.sh -a <account-alias>. Required once masters_enabled = true."
}

variable "mcs_ca_data_url" {
  type        = string
  default     = null
  description = "Output of scripts/ignition/extract-mcs-ca.sh -a <account-alias>. Required once masters_enabled = true."
}

variable "cluster_infra_id" {
  type        = string
  default     = null
  description = <<-EOT
    The infraID from .ignition/<account-alias>/metadata.json (e.g.
    "horizon-7t7mq") -- regenerated fresh on every `openshift-install create
    manifests` run, so this is a phase-specific -var like rhcos_ami_id, not
    something committed to tfvars. Tags master/bootstrap instances
    kubernetes.io/cluster/<infraID>=owned -- the in-cluster AWS
    cloud-controller-manager refuses to initialize any node without this tag
    on its own instance (confirmed for real: "AWS cloud failed to find
    ClusterID", instance already correctly identified via
    ec2:DescribeInstances, just missing this specific tag).
  EOT
}

# Phase toggles -- flipped via CLI -var at each stage of docs/runbook.md, not committed
# to accounts/*.tfvars, so tfvars git history reflects steady-state config,
# not transient bring-up state.

variable "masters_enabled" {
  type    = bool
  default = false
}

variable "bootstrap_enabled" {
  type    = bool
  default = false
}
