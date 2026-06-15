# Onboarding

Get a new engineer from `git clone` to a deployable environment in one command.

```bash
make onboard
```

That script (`scripts/onboard.sh`) is idempotent and does four things:

1. **Tooling check** — confirms `terraform` and `aws` (required) and warns if
   `docker`/`python` are missing (only needed in later phases).
2. **Authentication** — if you're already authenticated it moves on; otherwise it
   uses the `genai-ka` SSO profile and runs `aws sso login` for you. If no profile
   exists yet, it prints exact first-time setup steps.
3. **Identity & region** — prints the account, caller ARN, and region so you can
   confirm you're in the right place.
4. **Bedrock access** — checks that the Claude (agent) and Titan (embedding) model
   families are enabled in `us-east-1`, warning you early if they aren't.

## Authentication model

| Audience | Mechanism | Notes |
|----------|-----------|-------|
| **Humans (local)** | AWS IAM Identity Center (SSO) | First login is interactive *by design* — no keys in the repo. |
| **CI/CD** | GitHub OIDC | Zero stored credentials; see `.github/workflows/cd.yml`. |

**Why the first login can't be fully automated:** authenticating to an identity
provider is a deliberate human step. We never bake long-lived AWS access keys into
source control. What *is* automated is everything around it — the profile template,
the login command, and the environment verification — so onboarding is one command.

## First-time SSO setup

```bash
cp aws/config.example ~/.aws/config     # then edit the <PLACEHOLDER> values
aws sso login --profile genai-ka
make onboard
```

Prefer IAM access keys instead? Run `aws configure` and `make onboard` will detect
the default credential chain.

## Troubleshooting

- **"No AWS credentials"** — run the first-time SSO setup above, or `aws configure`.
- **Session expired** — re-run `make onboard`; it re-triggers `aws sso login`.
- **Bedrock model warnings** — open the Bedrock console → Model access, and enable
  Claude Sonnet + Titan Text Embeddings in `us-east-1`.
- **Use a different profile name** — `GENAI_KA_PROFILE=myprofile make onboard`.
