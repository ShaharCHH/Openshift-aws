provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Purpose   = "ocp-preflight"
      ManagedBy = "terraform-test"
    }
  }
}
