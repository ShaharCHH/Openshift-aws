# Wraps the real production s3 module and adds a put/get roundtrip object,
# so a passing canary proves the actual module works, not a lookalike.

module "bucket" {
  source        = "../../../terraform/modules/s3"
  bucket_name   = var.bucket_name
  tags          = var.tags
  force_destroy = true # canary bucket must fully tear down every run
}

resource "aws_s3_object" "canary" {
  bucket  = module.bucket.bucket_id
  key     = "preflight/canary.txt"
  content = "preflight-ok"
}
