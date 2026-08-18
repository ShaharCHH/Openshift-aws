variable "bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name (e.g. include the account id)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the bucket"
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = <<-EOT
    Allow `terraform destroy` to delete this bucket even if it still
    contains (versioned) objects. Defaults to false — the production
    ignition/haproxy-config bucket is long-lived and versioned on purpose,
    so an accidental `destroy` shouldn't silently wipe history. Preflight's
    canary bucket sets this true since it's meant to be fully torn down
    every run.
  EOT
}
