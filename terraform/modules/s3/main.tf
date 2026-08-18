# Bucket used to stage two things, both pulled down by the bastion using its
# own IAM role (normal SigV4-authenticated S3 access — no anonymous reads,
# no VPC endpoint needed):
#   ignition/{bootstrap,master,worker}.ign
#   haproxy/haproxy.cfg
#
# The bastion then re-serves the ignition files to cluster nodes itself, over
# plain HTTP on the private VPC network only (RHCOS's Ignition fetcher does a
# bare, unsigned GET — it can't do IAM/SigV4 — so *something* has to bridge
# "IAM-authenticated" to "anonymous", and that's the bastion's job, not S3's).
# See docs/architecture.md for the full boot-time fetch chain and why this
# replaced an earlier S3-Gateway-VPC-Endpoint design (ec2:CreateVpcEndpoint
# turned out to be SCP-blocked in the account this was built against).

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
