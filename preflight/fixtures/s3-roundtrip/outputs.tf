output "bucket_id" {
  value = module.bucket.bucket_id
}

output "object_etag" {
  value = aws_s3_object.canary.etag
}
