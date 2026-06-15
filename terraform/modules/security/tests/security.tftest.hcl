# Unit tests for the security (KMS) module. Offline via mock_provider.
#   terraform -chdir=terraform/modules/security init -backend=false
#   terraform -chdir=terraform/modules/security test

mock_provider "aws" {}

variables {
  name = "genai-ka-test"
}

run "kms_cmk_is_hardened" {
  command = plan

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true
    error_message = "KMS CMK must have automatic key rotation enabled"
  }
  assert {
    condition     = aws_kms_alias.this.name == "alias/genai-ka-test"
    error_message = "KMS alias must follow the alias/<name> convention"
  }
}
