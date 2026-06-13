# PII-Safe AI Invoice Generator — Enterprise Agentic AI Platform on AWS

**Status:** Design / spec
**Date:** 2026-06-13
**Owner:** thevamsithokala@gmail.com
**Purpose:** A deployable, industry-standard demo for a Senior AWS Platform Engineer role —
operationalizing an enterprise agentic AI platform (Bedrock + AgentCore + RAG) with
Infrastructure as Code, end-to-end service integration, security/compliance, observability,
CI/CD, and operational runbooks.

---

## 1. Summary

An enterprise agentic AI platform that turns messy source documents (purchase orders,
timesheets, contracts) — which contain PII — into clean, accurate **invoices**, safely.

The platform demonstrates the full Platform-Engineer responsibility set from the JD:
configuring and connecting AWS services end to end (Bedrock, **AgentCore**, Lambda, S3, ECS,
IAM, VPC, CloudWatch, OpenSearch Serverless, Comprehend), standing up RAG + agentic workflows,
provisioning everything with **Terraform**, securing it for compliance, and operating it with
dashboards and runbooks.

It is **deployable to a real AWS account** (the user has full access + Bedrock model access),
ships with its own **synthetic data** (including deliberately planted PII), and is driven
through a small **web UI/API on ECS Fargate** plus scripts.

### Build depth (decided)

**Core deep + rest real-but-light.** Everything in this spec is *designed*. Implementation tiers:

- **Fully built:** VPC/networking + PrivateLink, KMS, S3 tiers, PII pipeline (Comprehend),
  Bedrock Knowledge Base on OpenSearch Serverless, AgentCore (Runtime + Gateway + Memory +
  Identity), Bedrock Guardrails, Lambda tools, ECS Fargate UI/API, API Gateway, least-privilege
  IAM, CloudWatch dashboards/alarms + structured logging + tracing, CI/CD with security gates,
  a basic agent eval harness, AWS Budgets, SQS DLQs, Secrets Manager, WAF, synthetic data
  generator, Makefile/scripts, full docs + runbook.
- **Real-but-light / stubbed (documented as "production hardening"):** Amazon Macie,
  Security Hub / GuardDuty / AWS Config, multi-env staging/prod promotion, full Terratest
  coverage, DR/multi-region.

---

## 2. Goals & non-goals

### Goals
- Stand up the platform end to end with `terraform apply` + a `make demo` flow.
- Exercise every AWS service named in the JD in a way that is genuine, not decorative.
- Show senior-level rigor: least privilege, encryption, private networking, observability,
  CI/CD, testing/eval, FinOps guardrails, and operational documentation.
- Be reproducible and tear-downable (no bill shock).

### Non-goals
- Not a production invoicing product (no real accounting integrations, tax engines, ERP sync).
- Not multi-region/DR-complete (documented, not built).
- Not a polished consumer UI — the UI is functional, enough to demo the flow.

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
                    └── Observability: CloudWatch dashboards/alarms • X-Ray/OTel • AgentCore Observability •     │
                        Bedrock invocation logging • CloudTrail + S3 data events                                 │
```

### 3.2 Two agent entry paths
- **Document-driven:** "Generate an invoice from this PO." Agent reads the curated doc,
  extracts billable line items, looks up rates/terms via RAG, calls tools, produces the invoice.
- **Chat-driven:** "Invoice Acme for March consulting." Agent uses RAG over client terms, rate
  cards, and past invoices to draft the invoice.

Both produce a **draft** invoice (JSON + PDF) requiring human approval — a real
human-in-the-loop step to demo.

### 3.3 Foundation models & defaults
- **Agent model:** Claude Sonnet 4.x on Bedrock (latest available; configurable via variable).
- **Embeddings:** Amazon Titan Text Embeddings v2 for the Knowledge Base.
- **Fallback model:** a cheaper/secondary model id, configurable, for graceful degradation.
- **Region:** `us-east-1` (AgentCore + Bedrock + Comprehend available). Region is a variable.

---

## 4. PII / compliance architecture (defense-in-depth)

Tight-compliance requirement → four complementary layers:

1. **Pre-ingest detection + redaction (Amazon Comprehend).** The PII Lambda runs
   `DetectPiiEntities`; spans are masked; only the redacted copy proceeds.
2. **Severity-based quarantine.** High-severity types (SSN, bank/account, passport, etc.) or
   confidence above threshold → original moved to a **locked quarantine** S3 prefix, ingest
   **blocked** pending human approval; lower severity → redact + ingest. Thresholds/type-lists
   are configurable.
3. **Metadata tags + CloudWatch metrics/alarms.** Every document is tagged with its findings
   (types, counts, severity); metrics feed a **compliance dashboard** and alarms (e.g. spike in
   high-severity findings → SNS alert).
4. **Bedrock Guardrails at runtime.** A Guardrail with PII masking + content filters attached at
   the Bedrock invoke boundary, masking anything in agent inputs/outputs as a last line.

Supporting controls: KMS encryption at rest, PrivateLink so AI traffic never hits the public
internet, CloudTrail + S3 data events for audit, locked raw/quarantine prefixes, and a
`docs/compliance.md` mapping controls to GDPR/SOC2/HIPAA talking points. **Macie** (at-rest PII
discovery) is documented as a hardening layer.

---

## 5. Terraform module structure

Composable modules, per-environment roots, remote state.

```
AWS_GenAI_DEMO/
├── README.md                      # overview, arch diagram, quickstart, cost note, teardown
├── Makefile                       # init/plan/apply/seed/build/ingest/demo/test/destroy
├── docs/
│   ├── architecture.md            # diagram, responsibilities, design decisions, ADR links
│   ├── integration-guide.md       # how each service connects + data contracts per stage
│   ├── runbook.md                 # deploy order, failure modes + fixes, dashboards, rollback
│   ├── compliance.md              # PII controls → GDPR/SOC2/HIPAA mapping, retention
│   ├── cost.md                    # cost estimate, budgets, teardown
│   └── adr/                       # architecture decision records (0001-..., 0002-...)
├── terraform/
│   ├── environments/
│   │   └── dev/                   # backend.tf (S3 + DynamoDB lock), main.tf, dev.tfvars
│   │       # (staging/, prod/ documented as promotion targets, not built)
│   ├── modules/
│   │   ├── networking/            # VPC, 2-AZ public+private subnets, NAT, route tables,
│   │   │                          #   VPC endpoints: bedrock, bedrock-agentcore, s3(gw),
│   │   │                          #   comprehend, ecr.api/dkr, logs, secretsmanager, sts
│   │   ├── security/              # KMS CMK + rotation, WAF web ACL, IAM Access Analyzer,
│   │   │                          #   Secrets Manager secrets, baseline SCP-style guardrails
│   │   ├── storage/               # S3: raw / curated / quarantine / invoices / data-state
│   │   │                          #   SSE-KMS, versioning, lifecycle, bucket policies,
│   │   │                          #   EventBridge notifications
│   │   ├── pii_pipeline/          # EventBridge rule → PII Lambda (Comprehend) + SQS DLQ +
│   │   │                          #   idempotency table (DynamoDB) + SNS approval topic
│   │   ├── knowledge_base/        # OpenSearch Serverless collection + index (+IAM timing
│   │   │                          #   delay), Bedrock KB, S3 data source, ingestion role.
│   │   │                          #   Uses aws-ia/terraform-aws-bedrock where it simplifies.
│   │   ├── agent/                 # AgentCore Runtime + Gateway (Lambda targets→MCP tools) +
│   │   │                          #   Memory + Identity; Bedrock Guardrail; agent ECR image ref
│   │   ├── tools/                 # Lambda tool fns: rate_lookup, invoice_seq, render_pdf,
│   │   │                          #   persist_invoice; per-fn least-priv roles
│   │   ├── compute/               # ECS Fargate cluster + service (FastAPI UI/API), ALB,
│   │   │                          #   target group, autoscaling, ECR repo
│   │   ├── api/                   # API Gateway HTTP API → agent invoke, Cognito authorizer
│   │   ├── observability/         # CloudWatch dashboards + alarms + log groups + metric
│   │   │                          #   filters, X-Ray, Bedrock invocation logging, CloudTrail
│   │   └── finops/                # AWS Budgets + alerts, cost-allocation tag enforcement
│   └── ...
├── src/
│   ├── agent/                     # containerized agent (Strands Agents SDK + Bedrock), Dockerfile
│   ├── ui/                        # FastAPI UI/API container, Dockerfile, templates
│   └── lambda/
│       ├── pii_scanner/           # Comprehend scan/redact/route + tests
│       └── tools/                 # rate_lookup, invoice_seq, render_pdf, persist + tests
├── data/
│   ├── generator/                 # synthetic-data generator (clients, docs, planted PII)
│   └── fixtures/                  # generated sample POs, timesheets, contracts, rate cards,
│                                  #   past invoices (2-3 clients: Acme, Globex, ...)
├── tests/
│   ├── unit/                      # pytest: pii_scanner, tools, agent helpers
│   ├── integration/              # pipeline stage + KB retrieval integration tests
│   ├── eval/                      # agent eval harness: golden invoice scenarios + scoring
│   └── terraform/                 # terraform test / Terratest (core modules; rest documented)
├── .github/workflows/             # ci.yml (fmt/validate/tflint/tfsec/checkov/trivy/pytest/plan),
│                                  #   cd.yml (gated apply + image build/push), eval.yml
├── .pre-commit-config.yaml        # terraform fmt, tflint, detect-secrets/gitleaks, black/ruff
└── scripts/                       # seed_data, build_push_images, ingest_kb, smoke_test, demo, teardown
```

**Conventions:** remote state (S3 + DynamoDB lock); mandatory tags (`project`, `env`, `owner`,
`cost-center`, `data-classification`); naming `genai-inv-<env>-<resource>`; all config via
variables (region, model ids, severity thresholds, module toggles) so modules are reusable;
no hardcoded secrets (Secrets Manager / SSM).

---

## 6. IAM, security & networking

- **Least privilege per component:** separate scoped roles for the PII Lambda (Comprehend +
  read raw / write curated+quarantine), KB ingestion, AgentCore Runtime (Bedrock invoke + KB
  retrieve + Gateway), each tool Lambda, and ECS task/exec. No wildcard actions/resources;
  scoped to specific ARNs. Validated with IAM Access Analyzer.
- **Encryption:** one KMS CMK (rotation on); SSE-KMS on all buckets, CloudWatch logs, OpenSearch,
  SQS; TLS in transit.
- **Networking:** private subnets for ECS/Lambda/AgentCore; **PrivateLink/VPC endpoints** for
  Bedrock, AgentCore, S3, Comprehend, ECR, CloudWatch Logs, Secrets Manager, STS so AI/data
  traffic stays off the public internet. Public subnet only for the ALB.
- **Edge protection:** WAF on ALB + API Gateway; throttling/rate limiting; Cognito (or IAM) auth
  at API Gateway; AgentCore Identity for the agent.
- **Data isolation:** `raw` + `quarantine` prefixes locked (no KB access); only `curated`
  readable by the KB ingestion role; quarantine bucket denies all but the approval role.
- **Secrets:** Secrets Manager / SSM Parameter Store; `detect-secrets`/`gitleaks` in CI.

---

## 7. Observability & audit

- **Structured JSON logging** with correlation IDs threaded across pipeline stages and agent calls.
- **Tracing:** X-Ray / OpenTelemetry; **AgentCore Observability** for per-step agent traces and
  tool invocations.
- **Bedrock model-invocation logging** to S3/CloudWatch for prompt/response audit.
- **Audit:** CloudTrail + S3 data events.
- **Dashboards:** (1) platform health (latency, errors, throttles), (2) **compliance** (PII
  findings by type/severity, quarantine rate), (3) **GenAI/FinOps** (tokens, cost/req, RAG
  retrieval quality, invoice success rate).
- **Alarms → SNS:** high-severity PII spike, pipeline DLQ depth, agent error rate, budget breach.

---

## 8. CI/CD & GitOps

- **PR pipeline (`ci.yml`):** `terraform fmt -check`, `validate`, `tflint`, `tfsec`, `checkov`,
  `trivy` image scan, `gitleaks`, `pytest` unit tests, `terraform plan` (comment on PR).
- **Deploy pipeline (`cd.yml`):** gated `terraform apply` on merge to main (OIDC role, no static
  keys); build + push agent/UI images to ECR.
- **Eval pipeline (`eval.yml`):** run the agent eval harness against the golden scenarios; fail
  on regression below thresholds.
- **Pre-commit** hooks mirror the CI gates locally. Multi-env promotion (dev→staging→prod)
  documented.

---

## 9. Testing & evaluation

- **Unit (pytest):** PII scanner (redaction correctness, severity routing), each tool, agent helpers.
- **Integration:** pipeline stage contracts (raw→curated→KB), KB retrieval sanity.
- **IaC tests:** `terraform test`/Terratest for core modules (networking, storage, pii_pipeline);
  remainder documented.
- **Agent eval harness (`tests/eval/`):** golden set of invoice scenarios → scored on line-item
  extraction accuracy, RAG groundedness/citation, and final invoice correctness; thresholds
  enforced in CI.
- **Smoke/e2e (`scripts/smoke_test`):** post-deploy upload → pipeline → ingest → generate →
  verify draft invoice.

---

## 10. Reliability & FinOps

- **Resilience:** SQS DLQs, retries with backoff, idempotency keys (DynamoDB) on the pipeline;
  S3 versioning; multi-AZ; ECS health checks + autoscaling; agent fallback model + graceful
  degradation.
- **FinOps:** AWS Budgets + alerts, cost-allocation tags, GenAI/FinOps dashboard, OpenSearch OCU
  caps, S3 lifecycle policies, `make destroy` / `scripts/teardown` for clean teardown.
  `docs/cost.md` documents an estimate and the bill-shock warning.

---

## 11. Synthetic data

A generator (`data/generator/`) produces 2–3 fake clients (Acme, Globex, …) each with: a rate
card, a contract (terms/payment net days), timesheets, purchase orders, delivery notes, and a
couple of past invoices. Some documents **deliberately contain PII** (SSNs, personal emails,
phone numbers) so the scanner visibly catches, redacts, and/or quarantines during the demo.
Generated fixtures live in `data/fixtures/`; `scripts/seed_data` uploads them to S3(raw).

---

## 12. Demo & operations

- **One-command demo:** `make demo` = seed data → build/push images → `terraform apply` → ingest
  KB → smoke test, so an interviewer can run it end to end.
- **Runbook (`docs/runbook.md`):** deploy order, known failure modes + fixes (KB IAM propagation
  timing, Bedrock model-access errors, ingestion stuck, AgentCore image build), how to re-run
  ingestion, reading dashboards, rollback/teardown.
- **Integration guide (`docs/integration-guide.md`):** exact wiring + data contracts between
  every stage (the JD's "connect AWS services end to end").

---

## 13. JD coverage map

| JD requirement | Where covered |
|---|---|
| Bedrock, **AgentCore** + supporting infra | §3 agent, §5 `agent` module |
| Connect services end to end | §3 flow, §5 modules, `integration-guide.md` |
| RAG pipelines, agentic workflows, LLM services | §3, §4, §9 eval, `knowledge_base`/`agent` |
| IaC (Terraform/CloudFormation) | §5 Terraform; optional CFN stack noted |
| Troubleshoot across the stack | §7 observability, `runbook.md` |
| Collaborate / take architectural direction | this spec + ADRs |
| Platform documentation + runbooks | §12, `docs/` |
| Lambda, S3, ECS, IAM, VPC, CloudWatch | §5, §6, §7 (all first-class) |

---

## 14. Open items / future hardening (documented, not built now)

Macie, Security Hub/GuardDuty/Config, multi-env staging+prod promotion, full Terratest coverage,
multi-region DR, optional small CloudFormation stack to show IaC range, real ERP/accounting
integration.

---

## 15. Implementation phasing (for the plan)

1. **Foundation:** repo scaffold, backend/state, networking, security (KMS/WAF/secrets), storage.
2. **Data plane:** PII pipeline (Comprehend, DLQ, idempotency), synthetic data generator + seed.
3. **RAG:** OpenSearch Serverless + Bedrock KB + ingestion.
4. **Agent:** AgentCore Runtime/Gateway/Memory/Identity, Guardrails, Lambda tools, agent container.
5. **Edge/UI:** ECS Fargate FastAPI UI/API, API Gateway, Cognito, ALB/WAF.
6. **Ops:** observability, dashboards/alarms, FinOps budgets, runbook.
7. **Quality:** CI/CD, security gates, unit/integration tests, agent eval harness, smoke test.
8. **Docs:** README, architecture, integration guide, runbook, compliance, cost, ADRs.
