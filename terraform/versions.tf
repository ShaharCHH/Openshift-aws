terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # No backend block yet -- state is local for now. Migrating to the S3
  # backend described in accounts/backend/example.backend.hcl.sample is a
  # follow-up once scripts/bootstrap-state.sh (creates the per-account state
  # bucket) exists.
}
