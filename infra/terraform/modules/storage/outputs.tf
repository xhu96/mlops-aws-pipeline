output "models_bucket" {
  value = aws_s3_bucket.this["models"].bucket
}

output "models_bucket_arn" {
  value = aws_s3_bucket.this["models"].arn
}

output "capture_bucket" {
  value = aws_s3_bucket.this["capture"].bucket
}

output "capture_bucket_arn" {
  value = aws_s3_bucket.this["capture"].arn
}
