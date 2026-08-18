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
  description = "Output of scripts/ami-build/build-custom-ami.sh."
}

variable "instance_type" {
  type    = string
  default = "m5.xlarge" # runs a temporary control plane during bring-up; same reliability floor as a real master
}

variable "root_volume_size" {
  type    = number
  default = 100
}

variable "bastion_private_ip" {
  type        = string
  description = "Where the pointer ignition fetches bootstrap.ign from (bastion's ignition HTTP server, port 8080)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
