variable "aws_region" {
  type = string
}
variable "name_prefix" {
  type = string
}

provider "aws" {
  region = var.aws_region
}

run "create_bucket_and_object" {
  command = apply

  module {
    source = "./fixtures/s3-roundtrip"
  }

  providers = {
    aws = aws
  }

  variables {
    bucket_name = var.name_prefix
  }

  assert {
    condition     = length(output.object_etag) > 0
    error_message = "failed to write+read the canary object in S3"
  }
}
