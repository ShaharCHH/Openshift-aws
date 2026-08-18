variable "name_prefix" {
  type = string
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

variable "ami_id" {
  type        = string
  description = "Output of scripts/ami-build/build-custom-ami.sh -- an account-owned RHCOS AMI, never a foreign-owned one."
}

variable "instance_type" {
  type    = string
  default = "m5.xlarge" # Red Hat's documented minimum for control-plane nodes
}

variable "root_volume_size" {
  type        = number
  default     = 100 # GiB -- Red Hat's documented minimum; going lower risks kubelet disk-pressure evictions
  description = "gp3 root volume size in GiB."
}

variable "master_count" {
  type    = number
  default = 3
}

variable "bastion_private_ip" {
  type        = string
  description = "Where each master's pointer ignition fetches master.ign from (bastion's ignition HTTP server, port 8080)."
}

variable "mcs_ca_data_url" {
  type        = string
  description = <<-EOT
    The `data:...;base64,...` URL for the cluster's root-ca (same value as
    master.ign's own ignition.security.tls.certificateAuthorities[0].source).
    Embedded directly in the wrapper ignition so the CA is trusted from the
    outermost layer of config resolution, before any merging happens -- see
    ~/.claude/plans/soft-orbiting-puzzle.md's "masters reject bootstrap's MCS
    certificate" section for why master.ign's own self-referential CA
    declaration isn't trusted in time for its own config.merge fetch to
    api-int.
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}
