#!/usr/bin/env bash
# Run all offline Terraform tests (mock_provider — no AWS credentials, no cost).
# Single source of truth for `make test-tf` and the CI terraform-test job.
set -euo pipefail

dirs=(
  terraform
  terraform/modules/network
  terraform/modules/security
  terraform/modules/storage
)

fail=0
for d in "${dirs[@]}"; do
  echo "==== terraform test: ${d} ===="
  terraform -chdir="${d}" init -backend=false -input=false >/dev/null
  if ! terraform -chdir="${d}" test; then
    fail=1
  fi
done

if [ "${fail}" -ne 0 ]; then
  echo "Terraform tests FAILED" >&2
  exit 1
fi
echo "All Terraform tests passed."
