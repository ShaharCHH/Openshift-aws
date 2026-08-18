variable "bastion_instance_id" {
  type = string
}

variable "bucket_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "api_backends" {
  type        = list(object({ name = string, ip = string }))
  default     = []
  description = "Backends for the 6443 (API) frontend."
}

variable "mcs_backends" {
  type        = list(object({ name = string, ip = string }))
  default     = []
  description = "Backends for the 22623 (Machine Config Server) frontend."
}

variable "ingress_backends" {
  type        = list(object({ name = string, ip = string }))
  default     = []
  description = "Backends for the 443/80 (ingress) frontends."
}
