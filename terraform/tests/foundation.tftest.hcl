# Root integration test: verifies the modules compose and wire together.
# Per-resource assertions live in each module's own tests/ directory.
# Offline (mock_provider) — runs in CI with no AWS credentials:
#   terraform -chdir=terraform init -backend=false && terraform -chdir=terraform test

mock_provider "aws" {}

run "root_wires_two_azs_of_subnets" {
  command = plan

  assert {
    condition     = length(module.network.private_subnet_ids) == 2
    error_message = "Root should provision 2 private subnets via the network module"
  }

  assert {
    condition     = length(module.network.public_subnet_ids) == 2
    error_message = "Root should provision 2 public subnets via the network module"
  }
}
