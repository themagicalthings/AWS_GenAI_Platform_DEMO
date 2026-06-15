#!/usr/bin/env bash
# One-command onboarding for the GenAI Knowledge Assistant platform.
# Verifies local tooling, gets you authenticated to AWS, and confirms the
# environment is ready to deploy. Safe to re-run (idempotent).
#
#   make onboard            (or)      bash scripts/onboard.sh
#
# Auth model: humans authenticate via AWS IAM Identity Center (SSO); CI uses
# GitHub OIDC (no keys). Long-lived access keys are never stored in this repo.
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROFILE="${GENAI_KA_PROFILE:-genai-ka}"
AGENT_MODEL_HINT="claude-sonnet-4"
EMBED_MODEL_HINT="titan-embed-text-v2"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m %s\n' "$1"; }
err()  { printf '  \033[31m[x]\033[0m %s\n' "$1"; }

bold "1/4  Checking local tooling"
missing=0
for tool in terraform aws; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool: $("$tool" --version 2>&1 | head -1)"
  else
    err "$tool not found (required)"
    missing=1
  fi
done
for tool in docker python; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool present"
  else
    warn "$tool not found (needed for later phases, not the foundation apply)"
  fi
done
if [ "$missing" -ne 0 ]; then
  err "Install the required tools above, then re-run."
  exit 1
fi

bold "2/4  Authenticating to AWS"
have_profile() { aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE"; }

if aws sts get-caller-identity >/dev/null 2>&1; then
  ok "Already authenticated (default credential chain)"
elif have_profile; then
  if ! aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
    warn "Profile '$PROFILE' found but session expired - launching SSO login..."
    aws sso login --profile "$PROFILE" || { err "SSO login failed."; exit 1; }
  fi
  export AWS_PROFILE="$PROFILE"
  ok "Authenticated via profile '$PROFILE'"
else
  err "No AWS credentials and no '$PROFILE' profile configured."
  cat <<EOF

  First-time setup (pick one):
    - IAM Identity Center (recommended):
        cp aws/config.example ~/.aws/config    # then edit the placeholders
        aws sso login --profile $PROFILE
    - IAM access keys:
        aws configure

  Then re-run: make onboard
EOF
  exit 1
fi

bold "3/4  Verifying identity & region"
ok "Account:  $(aws sts get-caller-identity --query Account --output text)"
ok "Identity: $(aws sts get-caller-identity --query Arn --output text)"
ok "Region:   $REGION"

bold "4/4  Checking Bedrock model access in $REGION"
if models=$(aws bedrock list-foundation-models --region "$REGION" \
    --query 'modelSummaries[].modelId' --output text 2>/dev/null); then
  if printf '%s' "$models" | tr '\t' '\n' | grep -qi "$AGENT_MODEL_HINT"; then
    ok "Agent model family available (${AGENT_MODEL_HINT}*)"
  else
    warn "No '${AGENT_MODEL_HINT}' model listed - enable Claude access in the Bedrock console (phase 5)"
  fi
  if printf '%s' "$models" | tr '\t' '\n' | grep -qi "$EMBED_MODEL_HINT"; then
    ok "Embedding model family available (${EMBED_MODEL_HINT}*)"
  else
    warn "No '${EMBED_MODEL_HINT}' model listed - enable Titan Embeddings access (phase 3)"
  fi
else
  warn "Could not list Bedrock models (missing bedrock:ListFoundationModels?) - verify model access before phases 3/5"
fi

bold "Onboarding complete."
if [ "${AWS_PROFILE:-}" = "$PROFILE" ]; then
  echo "  Tip: keep using this profile in your shell:  export AWS_PROFILE=$PROFILE"
fi
echo "  Next:  make plan    (then, when ready,  make apply)"
