provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project      = "openshift-upi"
      AccountAlias = var.account_alias
      ManagedBy    = "terraform"
    }
  }
}
