# Enterprise Knowledge Assistant — Agentic AI Platform on AWS

A deployable RAG agent on **Amazon Bedrock AgentCore**, provisioned end-to-end with
Terraform. A deliberately simple product (a knowledge assistant that answers questions
over your documents and can call one tool) on a well-operated, enterprise-grade AWS
platform — built to demonstrate Senior Platform Engineer capability.

> Full design: [`docs/superpowers/specs/2026-06-13-knowledge-assistant-platform-design.md`](docs/superpowers/specs/2026-06-13-knowledge-assistant-platform-design.md)
> Implementation plan: [`docs/superpowers/plans/2026-06-13-knowledge-assistant-platform.md`](docs/superpowers/plans/2026-06-13-knowledge-assistant-platform.md)

## Architecture (target)

```
User -> ALB -> ECS Fargate (web UI) -> AgentCore Runtime (Strands + Claude on Bedrock)
                                          |- Bedrock Knowledge Base (RAG) -> OpenSearch Serverless <- S3 (docs)
                                          |- AgentCore Gateway -> Lambda tool (create_ticket)
                                          |- AgentCore Memory
                                          \- AgentCore Observability -> CloudWatch / X-Ray
   inside a VPC (PrivateLink) - least-privilege IAM - KMS - WAF - CI/CD - runbooks
```

## Quickstart

```bash
make onboard     # verify tooling, authenticate to AWS, check Bedrock access
make plan        # preview the infrastructure
make apply       # provision it
make test        # offline Terraform tests + Python tests (no AWS needed)
make destroy     # tear everything down
```

New here? See **[docs/onboarding.md](docs/onboarding.md)**.

## Repository layout

| Path | What |
|------|------|
| `terraform/` | Root config + modules (`network`, `security`, `storage`, ...) |
| `terraform/**/tests/` | Offline `terraform test` suites (`mock_provider`, no AWS) |
| `services/` | Application code (agent, UI, Lambda tools) — added in later phases |
| `scripts/` | `onboard.sh`, deploy/ingest/test helpers |
| `docs/` | Architecture, onboarding, CI/CD, runbook, design + plan |
| `.github/workflows/` | CI (validate/test/security) and CD (manual, OIDC) |

## CI/CD & security

Everything verifiable without AWS runs on every PR at zero cost (see
[`docs/ci-cd.md`](docs/ci-cd.md)). CD is manual and uses GitHub OIDC — no stored
credentials. Secrets live in KMS-encrypted resources; AgentCore enterprise
trade-offs are analyzed in
[`docs/agentcore-enterprise-bottlenecks.md`](docs/agentcore-enterprise-bottlenecks.md).

> Status: foundation (network, security, storage) implemented and CI-green;
> RAG, agent, UI, and observability follow the plan's phases 3-8.
