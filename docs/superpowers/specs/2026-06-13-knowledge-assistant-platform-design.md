# Enterprise Knowledge Assistant — Agentic AI Platform on AWS (Platform-Engineer Demo)

**Status:** Design / spec
**Date:** 2026-06-13
**Owner:** thevamsithokala@gmail.com
**Reference:** Amazon Bedrock AgentCore docs — https://docs.aws.amazon.com/bedrock-agentcore/

---

## 1. What this is and why

A **deliberately simple product** sitting on a **real, well-operated AWS platform**, built to
prove the candidate can do the Senior **Platform Engineer** job: *configure, connect, and
operationalize* the AWS infrastructure under an enterprise **agentic AI** platform
(Bedrock + AgentCore + RAG), with Infrastructure as Code, end-to-end integration, security,
observability, and operational runbooks.

**The product is just a vehicle.** The hiring signal is the platform, so the app stays trivial
and the effort goes into standing up and wiring the AWS services the JD names.

**Product:** an **Enterprise Knowledge Assistant** — a RAG agent, hosted on **AgentCore
Runtime**, that answers questions over documents dropped in S3 (indexed by a Bedrock Knowledge
Base) and can call **one Lambda tool** exposed through **AgentCore Gateway** (e.g. "create a
support ticket"). Accessed via a small web UI on ECS Fargate.

Deployable to a real AWS account (user has full access + Bedrock model access), ships with sample
documents, and is demoable in ~5 minutes.

---

## 2. Goals & non-goals

### Goals
- Stand up Bedrock + **AgentCore** (Runtime, Gateway, Memory, Identity, Observability) end to end.
- Connect S3, Lambda, ECS, IAM, VPC, CloudWatch, OpenSearch Serverless into one working flow.
- Provision it all with **Terraform** — modular, repeatable, one-command deploy + teardown.
- Operate it: dashboards, logs/traces, and a runbook covering real failure modes.
- Keep it small enough to fully build and clearly explain.

### Non-goals
- No PII pipeline, no multi-account org, no SCPs/landing zone (over-scope for this demo).
- No multi-region/DR. Single environment (`dev`), single Terraform state.
- Not a polished product UI — functional chat + upload is enough.

---

## 3. Architecture

```
                         ┌──────────────── VPC (private subnets + PrivateLink) ────────────────┐
                         │                                                                      │
 User ─▶ ALB ─▶ ECS Fargate (web UI) ─▶ AgentCore Runtime (Strands + Claude on Bedrock)         │
                         │                     │                                                │
                         │                     ├─ Bedrock Knowledge Base (RAG) ─▶ OpenSearch     │
                         │                     │        ▲                          Serverless    │
                         │                     │        └──────────── S3 (documents) ───────────┤
                         │                     ├─ AgentCore Gateway ─▶ Lambda tool (create_ticket)│
                         │                     ├─ AgentCore Memory (multi-turn)                   │
                         │                     └─ AgentCore Identity (Cognito)                    │
                         │                                                                        │
                         └── Observability: AgentCore Observability + CloudWatch + X-Ray (OTEL)   │
                             Security: least-privilege IAM, KMS at rest, PrivateLink, WAF on ALB  │
```

### 3.1 Request flow
1. User opens the ECS-hosted web UI, signs in (Cognito), asks a question.
2. UI calls **AgentCore Runtime**; the agent (Strands Agents SDK + Claude on Bedrock) decides
   whether to retrieve, answer, or call a tool.
3. **RAG:** agent queries the **Bedrock Knowledge Base**, which searches the **OpenSearch
   Serverless** vector index built from documents in **S3**.
4. **Tool:** if the user asks to act (e.g. "open a ticket"), the agent calls the **Lambda tool**
   via **AgentCore Gateway** (Lambda → MCP tool); the Lambda writes a record to DynamoDB and
   returns a ticket id.
5. **Memory:** AgentCore Memory keeps multi-turn context per session.
6. **Observability:** every step is traced via AgentCore Observability + X-Ray into CloudWatch.

### 3.2 Defaults (all variables)
- **Agent model:** Claude Sonnet 4.x on Bedrock. **Embeddings:** Amazon Titan Text Embeddings v2.
- **Region:** `us-east-1`. **Env:** `dev` (single).

### 3.3 Sample data
A handful of fake enterprise policy docs (HR / IT / product FAQs) under `data/` — enough to make
RAG answers obviously grounded in the corpus during a demo.

---

## 4. AWS services & how each is used (JD service coverage)

| Service | Role in the platform |
|---|---|
| **Amazon Bedrock** | Foundation model (Claude) for the agent; Titan embeddings for the KB |
| **AgentCore Runtime** | Serverless hosting of the agent container (image in ECR) |
| **AgentCore Gateway** | Exposes the Lambda tool to the agent as an MCP tool |
| **AgentCore Memory** | Short-term multi-turn conversation memory |
| **AgentCore Identity** | Agent identity / inbound auth via Cognito |
| **AgentCore Observability** | Per-step agent traces (OTEL → CloudWatch) |
| **Bedrock Knowledge Base** | Managed RAG over the document corpus |
| **OpenSearch Serverless** | Vector store backing the Knowledge Base |
| **S3** | Document corpus + Terraform state + agent/UI artifacts |
| **Lambda** | The single agent tool (`create_ticket`) |
| **ECS Fargate + ALB** | Hosts the web UI/API container |
| **DynamoDB** | Ticket store written by the Lambda tool |
| **IAM** | Least-privilege roles per component |
| **VPC + PrivateLink** | Private networking; AI traffic stays off the public internet |
| **CloudWatch + X-Ray** | Logs, metrics, dashboards, traces, alarms |
| **KMS / Cognito / WAF** | Encryption at rest, user auth, edge protection |

---

## 5. Repository & Terraform structure (right-sized)

One Terraform root, one state, clean modules. Readable end to end.

```
AWS_GenAI_DEMO/
├── README.md                  # overview, arch diagram, prerequisites, quickstart, cost, teardown
├── Makefile                   # init / plan / apply / ingest / demo / destroy
├── docs/
│   ├── architecture.md        # diagram + component responsibilities + key decisions
│   ├── integration-guide.md   # exactly how each service connects (data contracts, ARNs, wiring)
│   └── runbook.md             # deploy order, failure modes + fixes, dashboards, rollback/teardown
├── terraform/
│   ├── backend.tf             # S3 + DynamoDB state lock
│   ├── providers.tf  variables.tf  outputs.tf  main.tf   # single root, wires the modules
│   ├── dev.tfvars
│   └── modules/
│       ├── network/           # VPC, public+private subnets, NAT, VPC endpoints/PrivateLink
│       ├── knowledge_base/    # S3 docs bucket + OpenSearch Serverless + Bedrock KB + data source
│       ├── agent/             # AgentCore Runtime + Gateway + Memory + Identity; ECR repo
│       ├── tool/              # Lambda tool (create_ticket) + DynamoDB table + scoped role
│       ├── app/               # ECS Fargate service + ALB + Cognito + WAF + ECR repo
│       └── observability/     # CloudWatch dashboard, log groups, alarms, X-Ray
├── services/
│   ├── agent/                 # Strands + Bedrock agent code + Dockerfile
│   ├── ui/                    # small FastAPI chat/upload UI + Dockerfile
│   └── lambda_tool/           # create_ticket handler + tests
├── data/                      # sample policy/FAQ documents to ingest
├── .github/workflows/ci.yml   # fmt + validate + tflint + plan (PR); manual apply
└── scripts/
    ├── deploy.sh  ingest.sh  demo.sh  destroy.sh
```

**Conventions:** remote state (S3 + DynamoDB lock, SSE-KMS); tags `project`/`env`/`owner`;
naming `genai-ka-<env>-<resource>`; everything parameterized (region, model ids, sizes); no
hardcoded secrets (SSM/Secrets Manager).

**Known gotcha (in runbook):** after creating the OpenSearch Serverless data-access policy, add a
short delay before creating the Bedrock KB so IAM/permissions propagate (documented pattern).

---

## 6. Security (proportionate)

- **Least-privilege IAM** per component: agent runtime role (Bedrock invoke + KB retrieve +
  Gateway), Lambda tool role (DynamoDB write only), ECS task/exec roles, KB ingestion role.
  Scoped to specific ARNs, no wildcards.
- **Encryption:** KMS CMK for S3, logs, OpenSearch; TLS in transit.
- **Networking:** private subnets for ECS/agent; **VPC endpoints/PrivateLink** for Bedrock,
  AgentCore, S3, ECR, CloudWatch Logs, STS. Public subnet only for the ALB.
- **Edge/auth:** Cognito at the UI; WAF on the ALB; AgentCore Identity for the agent.

---

## 7. Observability & troubleshooting

- **Structured JSON logs** with a correlation id from UI → agent → tool.
- **AgentCore Observability + X-Ray** traces (OTEL) for per-step agent/tool visibility.
- **CloudWatch dashboard:** latency, errors, agent invocations, KB retrieval count, tool calls,
  token usage; **alarms → SNS** on error rate and Lambda failures.
- **runbook.md** turns this into a troubleshooting guide (the JD's "troubleshoot across the AWS
  stack"): connectivity (endpoint/SG/IAM), KB ingestion stuck, model-access errors, cold starts.

---

## 8. Automation, CI & docs

- **Makefile / scripts:** `make demo` = `apply` → `ingest` (load sample docs into the KB) →
  open the UI URL. `make destroy` tears everything down.
- **CI (`ci.yml`):** `terraform fmt -check`, `validate`, `tflint`, `plan` on PRs (apply stays
  manual / local for the demo). Keeps the repeatable-deploy story without heavyweight pipelines.
- **Docs (the JD's documentation bullet):**
  - `README.md` — what it is, architecture diagram, prerequisites, one-command quickstart, cost
    estimate + teardown.
  - `architecture.md` — components + responsibilities + decisions (why AgentCore, why OpenSearch
    Serverless).
  - `integration-guide.md` — exact wiring and data contracts between every service.
  - `runbook.md` — operational runbook: deploy order, failure modes + fixes, dashboards, rollback.

---

## 9. JD coverage map

| JD requirement | Where covered |
|---|---|
| Configure/operationalize Bedrock, **AgentCore** + supporting infra | §3, §4, `modules/agent` |
| Connect AWS services end to end (compute/storage/network/AI) | §3.1, `integration-guide.md` |
| Stand up RAG pipelines, agentic workflows, LLM services | §3, `modules/knowledge_base`, `services/agent` |
| IaC for consistent, repeatable deployments | §5 Terraform + §8 Makefile/CI |
| Troubleshoot across the AWS stack | §7 observability + `runbook.md` |
| Take architectural direction, execute independently | this spec + ADR-style decisions in docs |
| Platform documentation, integration guides, runbooks | §8, `docs/` |
| Lambda, S3, ECS, IAM, VPC, CloudWatch (hands-on) | §4, §5, §6, §7 |

---

## 10. Implementation phasing (for the plan)

1. **Scaffold + state:** repo layout, `backend.tf` (S3 + DynamoDB), providers, variables, CI.
2. **Network:** VPC, subnets, NAT, VPC endpoints/PrivateLink.
3. **Knowledge base:** S3 docs bucket, OpenSearch Serverless, Bedrock KB + data source, sample
   docs + `ingest.sh`.
4. **Tool:** Lambda `create_ticket` + DynamoDB + scoped IAM.
5. **Agent:** agent container (Strands + Bedrock), ECR, AgentCore Runtime + Gateway (Lambda
   target) + Memory + Identity.
6. **App:** ECS Fargate UI container + ALB + Cognito + WAF.
7. **Observability:** CloudWatch dashboard, alarms, X-Ray, log wiring.
8. **Docs + demo:** README, architecture, integration guide, runbook; `make demo` / `make destroy`.

---

## 11. Future extensions (documented, not built)

PII pre-ingest scanning (Comprehend), multi-environment promotion, multi-account/SCPs,
policy-as-code gates, agent eval harness, AWS Budgets/FinOps, a CloudFormation variant to show
IaC range. Each is a clean add-on to the structure above.
