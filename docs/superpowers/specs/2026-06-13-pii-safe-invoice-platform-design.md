# PII-Safe AI Invoice Generator — Enterprise Agentic AI Platform on AWS

**Status:** Design / spec
**Date:** 2026-06-13
**Owner:** thevamsithokala@gmail.com
**Purpose:** A deployable, **enterprise-reference-architecture** demo for a Senior AWS Platform
Engineer role — operationalizing an enterprise agentic AI platform (Bedrock + AgentCore + RAG)
with layered Infrastructure as Code, governance, security/compliance, observability, CI/CD,
policy-as-code, and operational runbooks.

---

## 1. Summary

An enterprise agentic AI platform that turns messy source documents (purchase orders,
timesheets, contracts) — which contain PII — into clean, accurate **invoices**, safely.

The platform demonstrates the full Platform-Engineer responsibility set from the JD:
configuring and connecting AWS services end to end (Bedrock, **AgentCore**, Lambda, S3, ECS,
IAM, VPC, CloudWatch, OpenSearch Serverless, Comprehend), standing up RAG + agentic workflows,
provisioning everything with **Terraform** structured as **layered stacks + a versioned module
library**, governing it with **policy-as-code** and security tooling, and operating it with
dashboards and runbooks.

It is **deployable to a real AWS account** (the user has full access + Bedrock model access),
ships with its own **synthetic data** (including deliberately planted PII), and is driven
through a small **web UI/API on ECS Fargate** plus scripts.

### 1.1 Account topology (decided)

**Single-account, multi-account-ready.** Deploys today into one sandbox account, but the code is
written for multi-account from day one:
- **Provider aliases + assume-role per logical account** (management / log-archive / security /
  workload). In the POC all aliases resolve to the same account; flipping to true multi-account
  is a variable change, not a rewrite.
- **SCPs and IAM Identity Center** defined as code (applied if an Organization exists, otherwise
  validated in CI as artifacts).
- **Layered state** so each layer maps cleanly onto a future per-account boundary.
No AWS Organizations / Control Tower setup is required to run it.

### 1.2 Build depth (decided)

**Core deep + rest real-but-light.** With the enterprise model, security tooling is **promoted
into a first-class `30-security` layer** (no longer "future hardening").

- **Fully built:** layered IaC + module library, policy-as-code gate, networking + PrivateLink,
  KMS, S3 tiers, PII pipeline (Comprehend), Bedrock KB on OpenSearch Serverless, AgentCore
  (Runtime + Gateway + Memory + Identity), Bedrock Guardrails, Lambda tools, ECS Fargate UI/API,
  API Gateway + Cognito, least-privilege IAM + permission boundaries, **GuardDuty / Security Hub
  / AWS Config / Macie / IAM Access Analyzer**, WAF, observability (dashboards/alarms/OTel/X-Ray)
  + Bedrock invocation logging + CloudTrail, CI/CD per layer + drift detection, agent eval
  harness, AWS Budgets/FinOps, SQS DLQs, Secrets Manager, synthetic data, docs + runbooks.
- **Real-but-light / documented:** true multi-account org rollout, Transit Gateway hub-spoke,
  multi-region DR, full Terratest coverage across every module, Spacelift/Atlantis (we use
  GitHub Actions OIDC instead).

---

## 2. Goals & non-goals

### Goals
- Stand up the platform end to end via layered `terraform apply` + a `task demo` flow.
- Exercise every AWS service named in the JD genuinely, with enterprise governance around it.
- Show senior rigor: isolated state/blast radius, least privilege + permission boundaries,
  encryption, private networking, policy-as-code, security tooling, observability, CI/CD,
  testing/eval, FinOps guardrails, and operational documentation.
- Be reproducible and tear-downable (no bill shock).

### Non-goals
- Not a production invoicing product (no real ERP/tax/accounting integrations).
- Not a live AWS Organizations landing zone (multi-account-ready code, single-account deploy).
- Not multi-region/DR-complete (documented, not built).
- Not a polished consumer UI — functional, enough to demo the flow.

---

## 3. Architecture

### 3.1 End-to-end flow

```
                    ┌──────────────────────────── VPC (private subnets + PrivateLink) ───────────────────────────┐
                    │                                                                                            │
 Client ─▶ WAF ─▶ ALB ─▶ ECS Fargate (FastAPI UI/API) ─▶ API Gateway (Cognito auth) ─▶ AgentCore Runtime        │
                    │                                                                   (Strands agent + Claude) │
 Upload doc ─▶ S3(raw) ─(EventBridge)─▶ Lambda PII scanner (Comprehend)                        │  │  │           │
                    │        │                  │                                              │  │  │           │
                    │        ├─ high severity ─▶ S3(quarantine, locked) + block + SNS          │  │  │           │
                    │        └─ low/none ──────▶ redact ─▶ S3(curated) ─▶ Bedrock KB ─▶ OpenSearch Serverless    │
                    │                                                          ▲           │   │  │  │           │
                    │                                                          └── RAG retrieve ─┘  │  │         │
                    │   AgentCore Gateway ─▶ Lambda tools: rate_lookup, invoice_seq, render_pdf, persist         │
                    │   AgentCore Memory (short/long term) • Bedrock Guardrails (PII mask at runtime)            │
                    │   Output: invoice JSON + PDF ─▶ S3(invoices, draft state)                                  │
                    │                                                                                            │
                    └── Security: GuardDuty • SecurityHub • Config • Macie • Access Analyzer • CloudTrail        │
                        Observability: CloudWatch dashboards/alarms • X-Ray/OTel • AgentCore Observability •     │
                        Bedrock invocation logging                                                               │
```

### 3.2 Two agent entry paths
- **Document-driven:** "Generate an invoice from this PO." Agent reads the curated doc,
  extracts billable line items, looks up rates/terms via RAG, calls tools, produces the invoice.
- **Chat-driven:** "Invoice Acme for March consulting." Agent uses RAG over client terms, rate
  cards, and past invoices to draft the invoice.

Both produce a **draft** invoice (JSON + PDF) requiring human approval — a real
human-in-the-loop step.

### 3.3 Foundation models & defaults
- **Agent model:** Claude Sonnet 4.x on Bedrock (latest available; configurable via variable).
- **Embeddings:** Amazon Titan Text Embeddings v2 for the Knowledge Base.
- **Fallback model:** a cheaper/secondary model id, configurable, for graceful degradation.
- **Region:** `us-east-1` (AgentCore + Bedrock + Comprehend available). Region is a variable.

---

## 4. PII / compliance architecture (defense-in-depth)

Tight-compliance requirement → four complementary layers:

1. **Pre-ingest detection + redaction (Amazon Comprehend).** PII Lambda runs `DetectPiiEntities`;
   spans masked; only the redacted copy proceeds.
2. **Severity-based quarantine.** High-severity types (SSN, bank/account, passport, etc.) or
   confidence above threshold → original moved to a **locked quarantine** prefix, ingest
   **blocked** pending human approval; lower severity → redact + ingest. Configurable.
3. **Metadata tags + CloudWatch metrics/alarms.** Every document tagged with its findings;
   metrics feed a **compliance dashboard** and alarms (high-severity spike → SNS alert).
4. **Bedrock Guardrails at runtime.** PII masking + content filters at the Bedrock invoke
   boundary, masking anything in agent inputs/outputs as a last line.

Supporting controls: KMS at rest, PrivateLink (AI traffic never hits the public internet),
CloudTrail + S3 data events, **Macie** at-rest PII discovery, locked raw/quarantine prefixes,
and `docs/compliance/` mapping controls to GDPR/SOC2/HIPAA.

---

## 5. Repository & IaC structure (enterprise model)

Layered stacks (isolated state, blast-radius containment) + a versioned module library +
policy-as-code.

```
AWS_GenAI_DEMO/
├── README.md  CONTRIBUTING.md  CODEOWNERS  CHANGELOG.md  SECURITY.md  LICENSE
├── Taskfile.yml                  # task bootstrap/plan/apply/deploy/seed/demo/test/destroy
├── .github/workflows/            # ci, cd-<layer>, drift-detection, policy-scan, eval, release
├── .pre-commit-config.yaml       # fmt, tflint, conftest, detect-secrets/gitleaks, ruff/black
├── docs/
│   ├── architecture/             # C4 diagrams, ADRs (adr/0001-…), well-architected-review.md
│   ├── runbooks/                 # one runbook per operational scenario
│   ├── integration-guide.md      # how each service connects + data contracts per stage
│   ├── compliance/               # control → GDPR/SOC2/HIPAA mapping, threat-model, retention
│   ├── cost.md                   # estimate, budgets, teardown
│   └── diagrams/
├── policies/                     # policy-as-code
│   ├── opa/                      # conftest rego (tags, encryption, no public S3, no 0.0.0.0/0)
│   ├── terraform-compliance/     # BDD-style compliance features
│   └── scp/                      # Service Control Policies as JSON (applied if Org present)
├── infra/                        # LIVE — layered stacks, each its own state, per-env dirs
│   ├── 00-bootstrap/             # TF state backend (S3+DynamoDB), GitHub OIDC provider, tags
│   ├── 10-foundation/<env>/      # account baseline, IAM Identity Center, permission boundaries,
│   │                             #   org KMS keys, log-archive bucket, provider/account aliases
│   ├── 20-network/<env>/         # VPC, 2-AZ subnets, NAT, endpoints/PrivateLink, Route53, (TGW-ready)
│   ├── 30-security/<env>/        # GuardDuty, SecurityHub, Config + rules, Macie, Access Analyzer, WAF
│   ├── 40-data/<env>/            # S3 tiers (raw/curated/quarantine/invoices), data KMS,
│   │                             #   PII pipeline (Comprehend, DLQ, idempotency), OpenSearch + KB
│   ├── 50-platform/<env>/        # AgentCore (Runtime/Gateway/Memory/Identity), Guardrails, ECR
│   ├── 60-app/<env>/             # ECS UI/API, ALB, API Gateway, Cognito, agent tool wiring
│   └── 70-observability/<env>/   # dashboards, alarms, OTel collector, X-Ray, budgets/FinOps
├── modules/                      # versioned reusable library — each w/ README, examples/, tests/, CHANGELOG
│   ├── networking/  kms/  storage/  security-baseline/
│   ├── pii-pipeline/  knowledge-base/  agentcore/  bedrock-guardrail/
│   ├── lambda-tool/  ecs-service/  api-gateway/  observability/  finops/
├── services/                     # application source
│   ├── agent/                    # Strands Agents SDK + Bedrock, Dockerfile
│   ├── ui-api/                   # FastAPI UI/API, Dockerfile, templates
│   └── functions/                # pii_scanner/ + tools (rate_lookup, invoice_seq, render_pdf, persist)
├── data/
│   ├── generator/                # synthetic-data generator (clients, docs, planted PII)
│   └── fixtures/                 # generated POs, timesheets, contracts, rate cards, past invoices
├── tests/
│   ├── unit/  integration/  e2e/  eval/   # eval = golden invoice scenarios + scoring
│   ├── policy/                   # conftest/terraform-compliance test cases
│   └── terraform/                # terraform test / Terratest (core modules)
└── scripts/                      # bootstrap, seed_data, build_push_images, deploy_layer,
                                  #   ingest_kb, smoke_test, demo, teardown
```

### 5.1 Layer dependency & deploy order
`00-bootstrap` → `10-foundation` → `20-network` → `30-security` → `40-data` → `50-platform`
→ `60-app` → `70-observability`. Each layer reads upstream outputs via **remote state data
sources** (`terraform_remote_state`), not hard-coded values. `scripts/deploy_layer` and the
`cd-<layer>` workflows respect this order.

### 5.2 Conventions
- **State:** S3 + DynamoDB lock, one key per layer per env, SSE-KMS, versioned.
- **Modules:** consumed by pinned version (Git tag / registry ref); semantic versioning + CHANGELOG.
- **Tagging (enforced by policy):** `project`, `env`, `owner`, `cost-center`, `data-classification`.
- **Naming:** `genai-inv-<env>-<layer>-<resource>`.
- **Config:** everything via variables (region, model ids, account map, severity thresholds,
  feature toggles). No hardcoded secrets — Secrets Manager / SSM.

---

## 6. IAM, security & governance

- **Least privilege + permission boundaries:** scoped roles per component (PII Lambda, KB
  ingestion, AgentCore Runtime, each tool Lambda, ECS task/exec). No wildcards; specific ARNs.
  A **permission boundary** caps every workload role. Validated by IAM Access Analyzer.
- **Governance as code:** SCPs (deny public S3, deny non-KMS, deny leaving region, deny root)
  in `policies/scp/`; **policy-as-code gate** (OPA/Conftest + tfsec + checkov +
  terraform-compliance) blocks merges that violate tag/encryption/network rules.
- **Security tooling (built):** GuardDuty, Security Hub, AWS Config + conformance rules, Macie,
  IAM Access Analyzer, WAF on ALB + API Gateway, CloudTrail (+ S3 data events).
- **Encryption:** KMS CMKs (rotation on) for data, logs, OpenSearch, SQS; TLS in transit.
- **Networking:** private subnets for ECS/Lambda/AgentCore; PrivateLink/VPC endpoints for
  Bedrock, AgentCore, S3, Comprehend, ECR, Logs, Secrets Manager, STS. Public subnet only for ALB.
- **Data isolation:** raw + quarantine locked (no KB access); only curated readable by the KB
  ingestion role; quarantine denies all but the approval role.
- **Identity:** IAM Identity Center (workforce), Cognito (app users), AgentCore Identity (agent).

---

## 7. Observability & audit

- **Structured JSON logging** with correlation IDs threaded across pipeline stages and agent calls.
- **Tracing:** X-Ray / OpenTelemetry collector; **AgentCore Observability** for per-step agent
  traces and tool invocations.
- **Bedrock model-invocation logging** to S3/CloudWatch (prompt/response audit).
- **Audit:** CloudTrail + S3 data events; Security Hub aggregates findings.
- **Dashboards (as code):** (1) platform health, (2) **compliance** (PII findings by
  type/severity, quarantine rate), (3) **GenAI/FinOps** (tokens, cost/req, RAG retrieval
  quality, invoice success rate). **SLOs/SLIs** defined for the agent path.
- **Alarms → SNS:** high-severity PII spike, DLQ depth, agent error rate, budget breach,
  GuardDuty/Security Hub critical findings.

---

## 8. CI/CD, policy-as-code & GitOps

- **PR pipeline (`ci.yml`):** `terraform fmt -check`, `validate`, `tflint`, **conftest (OPA)**,
  `tfsec`, `checkov`, `terraform-compliance`, `trivy` image scan, `gitleaks`, `pytest`, and a
  per-layer `terraform plan` posted as a PR comment.
- **Deploy pipeline (`cd-<layer>.yml`):** gated `apply` per layer on merge to main via **GitHub
  OIDC role (no static keys)**, honoring layer order; **manual approval** before higher envs.
- **Drift detection (`drift-detection.yml`):** scheduled `plan` per layer; alerts on drift.
- **Eval pipeline (`eval.yml`):** agent eval harness vs golden scenarios; fails on regression.
- **Release (`release.yml`):** module version tags + CHANGELOG; image tags to ECR.
- **Pre-commit** mirrors the gates locally. Promotion dev→staging→prod documented (single-account
  POC uses one env; structure supports more).

---

## 9. Testing & evaluation

- **Unit (pytest):** PII scanner (redaction correctness, severity routing), each tool, agent helpers.
- **Integration:** pipeline stage contracts (raw→curated→KB), KB retrieval sanity.
- **Policy tests:** conftest/terraform-compliance cases under `tests/policy/`.
- **IaC tests:** `terraform test`/Terratest for core modules (networking, storage, pii-pipeline,
  knowledge-base); remainder documented.
- **Agent eval harness (`tests/eval/`):** golden invoice scenarios → scored on line-item
  extraction accuracy, RAG groundedness/citation, and invoice correctness; thresholds enforced.
- **Smoke/e2e (`scripts/smoke_test`):** upload → pipeline → ingest → generate → verify draft.

---

## 10. Reliability & FinOps

- **Resilience:** SQS DLQs, retries with backoff, idempotency keys (DynamoDB) on the pipeline;
  S3 versioning; multi-AZ; ECS health checks + autoscaling; agent fallback model + graceful
  degradation. RPO/RTO + multi-region documented.
- **FinOps:** AWS Budgets + alerts, cost-allocation tags (policy-enforced), GenAI/FinOps
  dashboard, OpenSearch OCU caps, S3 lifecycle policies, `task destroy` / `scripts/teardown`.
  `docs/cost.md` documents estimate + bill-shock warning.

---

## 11. Synthetic data

A generator (`data/generator/`) produces 2–3 fake clients (Acme, Globex, …) each with: rate
card, contract (terms/payment net days), timesheets, purchase orders, delivery notes, past
invoices. Some documents **deliberately contain PII** (SSNs, personal emails, phone numbers) so
the scanner visibly catches, redacts, and/or quarantines during the demo. Fixtures live in
`data/fixtures/`; `scripts/seed_data` uploads them to S3(raw).

---

## 12. Demo & operations

- **One-command demo:** `task demo` = bootstrap → deploy layers in order → seed data →
  build/push images → ingest KB → smoke test.
- **Runbooks (`docs/runbooks/`):** per-scenario — deploy order, KB IAM propagation timing,
  Bedrock model-access errors, ingestion stuck, AgentCore image build, drift remediation,
  reading dashboards, rollback/teardown.
- **Integration guide (`docs/integration-guide.md`):** exact wiring + data contracts between
  every stage and every layer's remote-state outputs.

---

## 13. JD coverage map

| JD requirement | Where covered |
|---|---|
| Bedrock, **AgentCore** + supporting infra | §3, `50-platform`, `modules/agentcore` |
| Connect services end to end | §3, §5.1 layer wiring, `integration-guide.md` |
| RAG pipelines, agentic workflows, LLM services | §3, §4, §9 eval, `40-data`/`50-platform` |
| IaC (Terraform/CloudFormation) | §5 layered Terraform + module library |
| Automate env provisioning, repeatable deploys | §5, §8 CI/CD per layer + drift detection |
| Troubleshoot across the stack | §7 observability, `docs/runbooks/` |
| Collaborate / take architectural direction | this spec, ADRs, C4 diagrams |
| Platform documentation + runbooks | §12, `docs/` |
| Lambda, S3, ECS, IAM, VPC, CloudWatch | §5–§7 (all first-class) |
| Security/governance at scale (enterprise) | §6 (SCPs, boundaries, GuardDuty/SecurityHub/Config/Macie), §8 policy-as-code |

---

## 14. Open items / future hardening (documented, not built now)

True multi-account org rollout (Control Tower), Transit Gateway hub-spoke + centralized egress,
multi-region DR, full Terratest across every module, Spacelift/Atlantis, optional small
CloudFormation stack to show IaC range, real ERP/accounting integration.

---

## 15. Implementation phasing (for the plan)

1. **Bootstrap & foundation:** repo scaffold + standards files, `00-bootstrap` (state, OIDC),
   `10-foundation` (baseline, boundaries, Identity Center, KMS, log archive), provider/account map.
2. **Network & security:** `20-network` (VPC, endpoints/PrivateLink), `30-security`
   (GuardDuty/SecurityHub/Config/Macie/Access Analyzer/WAF), SCPs + policy-as-code gate.
3. **Data plane:** `40-data` — S3 tiers, PII pipeline (Comprehend, DLQ, idempotency), synthetic
   data generator + seed.
4. **RAG:** OpenSearch Serverless + Bedrock KB + ingestion (within `40-data`).
5. **Platform:** `50-platform` — AgentCore Runtime/Gateway/Memory/Identity, Guardrails, ECR,
   agent container, Lambda tools.
6. **Edge/UI:** `60-app` — ECS Fargate UI/API, ALB, API Gateway, Cognito.
7. **Ops:** `70-observability` — dashboards/alarms/OTel/X-Ray, FinOps budgets.
8. **Quality & docs:** CI/CD + drift + eval pipelines, unit/integration/policy tests, smoke test;
   README, architecture + ADRs + C4, integration guide, runbooks, compliance, cost.
