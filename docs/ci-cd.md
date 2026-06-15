# CI/CD Pipeline

This repo uses GitHub Actions. The design goal: **everything that can be verified
without AWS is verified on every PR, at zero cost**, and **anything that touches
AWS is manual, OIDC-authenticated, and human-approved**.

## CI — `.github/workflows/ci.yml` (runs on every PR / push)

| Job | What it does | Needs AWS? |
|-----|--------------|------------|
| **terraform-validate** | `fmt -check`, `init -backend=false`, `validate`, then `tflint` | No |
| **terraform-test** | Runs the offline module + root unit tests via `mock_provider` (`scripts/run_tf_tests.sh`) | No |
| **iac-security** | Checkov scans the Terraform for misconfigurations | No |
| **python-quality** | `ruff check`, `ruff format --check`, `pytest` (Python 3.12) | No |
| **secret-scan** | gitleaks scans history for committed secrets | No |

All five jobs run in parallel. `concurrency` cancels superseded runs on the same ref.
`permissions: contents: read` keeps the default token least-privilege.

### The Terraform unit tests
Native `terraform test` files using `mock_provider "aws"` — they execute with **no
credentials and create nothing**, asserting on the configuration we control:

- `terraform/tests/foundation.tftest.hcl` — root wiring (2 AZs of subnets compose).
- `terraform/modules/network/tests/` — VPC/subnet topology, 7 interface endpoints,
  private DNS on, endpoint SG scoped to the VPC CIDR (not the internet).
- `terraform/modules/security/tests/` — KMS rotation enabled, alias convention.
- `terraform/modules/storage/tests/` — docs bucket blocks all public access,
  versioning on, SSE-KMS.

Run locally: `make test-tf` (or `bash scripts/run_tf_tests.sh`). Python tests: `make test-py`.
Both: `make test`.

### Checkov policy
Currently `soft_fail: true` — findings appear as annotations but don't block, so
the platform can be built out incrementally. **Before production**, flip it to
hard-fail and record any accepted findings in a `.checkov.yaml` skip list with
justification.

## CD — `.github/workflows/cd.yml` (manual, gated)

Triggered only by **workflow_dispatch** with a `plan`/`apply` choice. It:
1. Assumes an AWS role via **GitHub OIDC** (`permissions: id-token: write`) — no
   long-lived access keys are ever stored.
2. Runs `terraform plan`; `apply` runs only if explicitly chosen.
3. Targets the **`production` GitHub Environment**, which should be configured with
   required reviewers so every apply waits for human approval.

### One-time setup required before CD works
1. Bootstrap remote state and put the real account id in `terraform/backend.tf`
   (see the runbook / plan task 0.2).
2. Create a GitHub OIDC provider + IAM deploy role trusting this repo; store the
   role ARN as the secret **`AWS_DEPLOY_ROLE_ARN`**.
3. Create the **`production`** Environment with required reviewers.

## Local hooks
`.pre-commit-config.yaml` mirrors the CI gates (terraform fmt/validate, ruff,
gitleaks, hygiene). Install with `pip install pre-commit && pre-commit install`.

## Dependency hygiene
`.github/dependabot.yml` keeps GitHub Actions, Terraform providers, and pip
dependencies patched on a weekly cadence.
