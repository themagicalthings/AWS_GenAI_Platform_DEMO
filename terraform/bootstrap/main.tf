terraform {
  required_providers { aws = { source = "hashicorp/aws", version = ">= 6.49" } }
}
provider "aws" { region = "us-east-1" }

resource "aws_s3_bucket" "state" {
  bucket = "genai-ka-dev-tfstate-${data.aws_caller_identity.me.account_id}"
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_dynamodb_table" "lock" {
  name         = "genai-ka-dev-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
data "aws_caller_identity" "me" {}
output "state_bucket" { value = aws_s3_bucket.state.bucket }
