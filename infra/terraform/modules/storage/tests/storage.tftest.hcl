# Buckets must be private, encrypted and TLS-only.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name       = "churn-test"
  account_id = "123456789012"
}

run "buckets_are_locked_down" {
  command = plan

  assert {
    condition     = alltrue([for b in aws_s3_bucket_public_access_block.this : b.block_public_acls && b.block_public_policy && b.restrict_public_buckets])
    error_message = "Every bucket must block public access"
  }
  assert {
    condition     = length(aws_s3_bucket_policy.this) == 2
    error_message = "Every bucket needs the TLS-only policy"
  }
  assert {
    condition     = aws_s3_bucket.this["models"].bucket == "churn-test-models-123456789012"
    error_message = "Bucket names must be account-scoped"
  }
  assert {
    condition     = aws_s3_bucket.this["models"].force_destroy == false
    error_message = "Buckets must survive terraform destroy by default"
  }
}
