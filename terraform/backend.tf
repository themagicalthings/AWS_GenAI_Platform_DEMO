terraform {
  required_version = ">= 1.9"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 6.49" } }
  # TODO: after running the bootstrap apply, replace <account_id> with the real account id
  # and run `terraform -chdir=terraform init` to migrate state to S3.
  backend "s3" {
    bucket         = "genai-ka-dev-tfstate-<account_id>"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "genai-ka-dev-tflock"
    encrypt        = true
  }
}
