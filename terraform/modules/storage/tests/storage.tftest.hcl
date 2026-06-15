# Unit tests for the storage (S3) module. Offline via mock_provider.
#   terraform -chdir=terraform/modules/storage init -backend=false
#   terraform -chdir=terraform/modules/storage test

mock_provider "aws" {}

variables {
  name        = "genai-ka-test"
  kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-1111-1111-1111-111111111111"
}

run "docs_bucket_blocks_public_access" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_public_access_block.docs.block_public_acls &&
      aws_s3_bucket_public_access_block.docs.block_public_policy &&
      aws_s3_bucket_public_access_block.docs.ignore_public_acls &&
      aws_s3_bucket_public_access_block.docs.restrict_public_buckets
    )
    error_message = "Docs bucket must block all four forms of public access"
  }
}

run "docs_bucket_versioning_and_encryption" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.docs.versioning_configuration[0].status == "Enabled"
    error_message = "Docs bucket must have versioning enabled"
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.docs.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "Docs bucket must use SSE-KMS"
  }
}
