# Enterprise Knowledge Assistant Platform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a deployable RAG agent on AWS — hosted on AgentCore Runtime, retrieving from a Bedrock Knowledge Base, calling one Lambda tool via AgentCore Gateway, with Memory, Cognito inbound auth, and CloudWatch/X-Ray observability — all provisioned with Terraform.

**Architecture:** A small ECS Fargate web UI calls an agent (Strands + Claude on Bedrock) running on AgentCore Runtime. The agent does RAG against a Bedrock Knowledge Base backed by OpenSearch Serverless over documents in S3, and calls a `create_ticket` Lambda exposed as an MCP tool through AgentCore Gateway. Everything runs in a VPC with PrivateLink, least-privilege IAM, and KMS encryption. One environment (`dev`), one Terraform state.

**Tech Stack:** Terraform (`hashicorp/aws` ≥ 6.49), Python 3.12 (Strands Agents SDK, boto3, FastAPI), Docker, AgentCore (Runtime/Gateway/Memory/Identity/Observability), Bedrock Knowledge Bases, OpenSearch Serverless, Lambda, DynamoDB, ECS Fargate, ALB, Cognito, WAF, CloudWatch, X-Ray. Tests: `pytest`, `terraform validate`/`tflint`/`terraform test`.

---

## Conventions (read once, apply to every task)

- **Region/env:** `us-east-1`, env `dev`. All names: `genai-ka-dev-<resource>`.
- **Terraform layout:** single root at `terraform/`, modules under `terraform/modules/`. Root wires modules and passes outputs between them.
- **Terraform task cycle (the "test loop" for infra):**
  1. Write/modify the module.
  2. `terraform fmt -recursive` then `terraform -chdir=terraform validate`.
  3. `tflint --chdir=terraform`.
  4. `terraform -chdir=terraform plan -var-file=dev.tfvars` and confirm the expected resources appear (this is the "does it do what I think" gate).
  5. Commit.
  `apply` happens only at the explicit **deploy + verify** tasks (end of each infra phase) to keep cost controlled.
- **Python task cycle:** strict TDD — failing test → run (see it fail) → minimal impl → run (pass) → commit.
- **AgentCore schema note:** `aws_bedrockagentcore_*` resources are new. For every AgentCore Terraform task, BEFORE writing the resource run context7 (`mcp__plugin_context7_context7__resolve-library-id` → `query-docs` for "terraform-provider-aws") or open the Terraform Registry page for the exact resource, and confirm the nested-block argument names against your provider version. The blocks below are correct in shape; verify field spellings against your pinned provider.
- **Cost guardrail:** OpenSearch Serverless and ECS/ALB incur hourly cost. Run `make destroy` (Task 8.x) when not demoing.
- **Prereqs (do once, manually):** AWS account with Bedrock model access enabled for Claude Sonnet 4.x and Titan Text Embeddings v2 in `us-east-1`; Docker running; Terraform ≥ 1.9; AWS CLI configured; `tflint`, `pytest`, `uv`/`pip` installed.

---

## File Structure

**Terraform root** (`terraform/`)
- `backend.tf` — S3 + DynamoDB remote state.
- `providers.tf` — aws provider (region, default tags), provider aliases (account-ready).
- `variables.tf` / `outputs.tf` / `dev.tfvars` — root inputs/outputs.
- `main.tf` — instantiates and wires all modules.

**Terraform modules** (`terraform/modules/`)
- `network/` — VPC, subnets, NAT, route tables, VPC endpoints/PrivateLink, SGs.
- `security/` — KMS CMK, WAF web ACL, Secrets/SSM params.
- `storage/` — S3 docs bucket (+ versioning, SSE-KMS, policy).
- `knowledge_base/` — OpenSearch Serverless collection+index, Bedrock KB, S3 data source, ingestion role.
- `tool/` — `create_ticket` Lambda, DynamoDB table, scoped role.
- `agent/` — ECR repo, AgentCore Memory, Gateway (+ Lambda target), Identity (Cognito), Runtime + endpoint, agent execution role.
- `app/` — ECS cluster/service, task defs, ALB, Cognito user pool, WAF assoc.
- `observability/` — CloudWatch dashboard, log groups, alarms, X-Ray, SNS.

**Application code** (`services/`)
- `lambda_tool/` — `handler.py`, `requirements.txt`, `tests/`.
- `agent/` — `agent.py`, `Dockerfile`, `requirements.txt`, `tests/`.
- `ui/` — `app.py` (FastAPI), `templates/`, `Dockerfile`, `requirements.txt`, `tests/`.

**Supporting**
- `data/` — sample policy/FAQ docs.
- `scripts/` — `deploy.sh`, `ingest.sh`, `smoke_test.py`, `destroy.sh`.
- `.github/workflows/ci.yml` — fmt/validate/tflint/plan + pytest.
- `Makefile`, `docs/` (architecture, integration-guide, runbook), `README.md`.

---

## Phase 0 — Repository scaffold & Terraform state

### Task 0.1: Repo scaffold + tooling config

**Files:**
- Create: `.gitignore` (exists — verify), `Makefile`, `terraform/.tflint.hcl`, `pyproject.toml`

- [ ] **Step 1: Create `pyproject.toml`** (pytest + ruff config)

```toml
[project]
name = "genai-ka"
version = "0.1.0"
requires-python = ">=3.12"

[tool.pytest.ini_options]
testpaths = ["services"]
addopts = "-q"

[tool.ruff]
line-length = 100
target-version = "py312"
```

- [ ] **Step 2: Create `terraform/.tflint.hcl`**

```hcl
plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
config {
  call_module_type = "local"
}
```

- [ ] **Step 3: Create `Makefile`**

```makefile
TF := terraform -chdir=terraform
TFVARS := -var-file=dev.tfvars

.PHONY: init fmt validate lint plan apply ingest demo destroy test
init:    ; $(TF) init
fmt:     ; terraform fmt -recursive
validate:; $(TF) validate
lint:    ; tflint --chdir=terraform
plan:    ; $(TF) plan $(TFVARS)
apply:   ; $(TF) apply $(TFVARS) -auto-approve
ingest:  ; python scripts/ingest.py
demo:    ; bash scripts/deploy.sh && python scripts/ingest.py && python scripts/smoke_test.py
destroy: ; $(TF) destroy $(TFVARS) -auto-approve
test:    ; pytest
```

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml terraform/.tflint.hcl Makefile
git commit -m "chore: repo scaffold (make, tflint, pytest config)"
```

### Task 0.2: Terraform remote state backend (bootstrap)

State bucket + lock table must exist before `init` with the S3 backend. Create them with a tiny one-shot Terraform config that uses local state, then configure the main backend to use them.

**Files:**
- Create: `terraform/bootstrap/main.tf`, `terraform/backend.tf`, `terraform/providers.tf`

- [ ] **Step 1: Create `terraform/bootstrap/main.tf`**

```hcl
terraform {
  required_providers { aws = { source = "hashicorp/aws", version = ">= 6.49" } }
}
provider "aws" { region = "us-east-1" }

resource "aws_s3_bucket" "state" {
  bucket = "genai-ka-dev-tfstate-${data.aws_caller_identity.me.account_id}"
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_dynamodb_table" "lock" {
  name         = "genai-ka-dev-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute { name = "LockID"; type = "S" }
}
data "aws_caller_identity" "me" {}
output "state_bucket" { value = aws_s3_bucket.state.bucket }
```

- [ ] **Step 2: Apply bootstrap**

Run:
```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply -auto-approve
```
Expected: outputs `state_bucket = genai-ka-dev-tfstate-<account_id>`. Note the bucket name.

- [ ] **Step 3: Create `terraform/backend.tf`** (replace `<bucket>` with the output)

```hcl
terraform {
  required_version = ">= 1.9"
  required_providers { aws = { source = "hashicorp/aws", version = ">= 6.49" } }
  backend "s3" {
    bucket         = "genai-ka-dev-tfstate-<account_id>"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "genai-ka-dev-tflock"
    encrypt        = true
  }
}
```

- [ ] **Step 4: Create `terraform/providers.tf`**

```hcl
provider "aws" {
  region = var.region
  default_tags { tags = { project = "genai-ka", env = var.env, owner = var.owner } }
}
```

- [ ] **Step 5: Create `terraform/variables.tf` (root, initial)**

```hcl
variable "region" { type = string, default = "us-east-1" }
variable "env"    { type = string, default = "dev" }
variable "owner"  { type = string, default = "thevamsithokala@gmail.com" }
variable "agent_model_id"     { type = string, default = "anthropic.claude-sonnet-4-5-20250929-v1:0" }
variable "embedding_model_id" { type = string, default = "amazon.titan-embed-text-v2:0" }
```
> Verify both model IDs against `aws bedrock list-foundation-models --region us-east-1` and update defaults if the exact IDs differ in your account.

- [ ] **Step 6: Create `terraform/dev.tfvars`**

```hcl
region = "us-east-1"
env    = "dev"
owner  = "thevamsithokala@gmail.com"
```

- [ ] **Step 7: Init main root + verify**

Run: `terraform -chdir=terraform init`
Expected: "Successfully configured the backend "s3"" and "Terraform has been successfully initialized!"

- [ ] **Step 8: Commit**

```bash
git add terraform/bootstrap terraform/backend.tf terraform/providers.tf terraform/variables.tf terraform/dev.tfvars
git commit -m "feat(infra): bootstrap remote state + provider/backend config"
```

---

## Phase 1 — Network

### Task 1.1: `network` module — VPC, subnets, NAT

**Files:**
- Create: `terraform/modules/network/main.tf`, `variables.tf`, `outputs.tf`

- [ ] **Step 1: Create `terraform/modules/network/variables.tf`**

```hcl
variable "name" { type = string }
variable "cidr" { type = string, default = "10.20.0.0/16" }
variable "azs"  { type = list(string), default = ["us-east-1a", "us-east-1b"] }
```

- [ ] **Step 2: Create `terraform/modules/network/main.tf`**

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = var.name }
}

resource "aws_subnet" "public" {
  for_each                = { for i, az in var.azs : az => i }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.cidr, 8, each.value)
  map_public_ip_on_launch = true
  tags = { Name = "${var.name}-public-${each.key}", tier = "public" }
}

resource "aws_subnet" "private" {
  for_each          = { for i, az in var.azs : az => i }
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.cidr, 8, each.value + 10)
  tags = { Name = "${var.name}-private-${each.key}", tier = "private" }
}

resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.this.id, tags = { Name = var.name } }

resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id
  tags = { Name = var.name }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route { cidr_block = "0.0.0.0/0", gateway_id = aws_internet_gateway.igw.id }
}
resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route { cidr_block = "0.0.0.0/0", nat_gateway_id = aws_nat_gateway.nat.id }
}
resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
```

- [ ] **Step 3: Create `terraform/modules/network/outputs.tf`**

```hcl
output "vpc_id"             { value = aws_vpc.this.id }
output "private_subnet_ids" { value = [for s in aws_subnet.private : s.id] }
output "public_subnet_ids"  { value = [for s in aws_subnet.public : s.id] }
```

- [ ] **Step 4: Wire into root `terraform/main.tf`**

```hcl
module "network" {
  source = "./modules/network"
  name   = "genai-ka-${var.env}"
}
```

- [ ] **Step 5: Validate + plan**

Run: `terraform fmt -recursive && terraform -chdir=terraform validate && terraform -chdir=terraform plan -var-file=dev.tfvars`
Expected: plan shows the VPC, 2 public + 2 private subnets, IGW, NAT, route tables. No errors.

- [ ] **Step 6: Commit**

```bash
git add terraform/modules/network terraform/main.tf
git commit -m "feat(infra): network module (VPC, subnets, NAT)"
```

### Task 1.2: `network` — security groups + VPC endpoints (PrivateLink)

**Files:**
- Modify: `terraform/modules/network/main.tf`, `outputs.tf`

- [ ] **Step 1: Append SGs + endpoints to `main.tf`**

```hcl
resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-vpce-"
  vpc_id      = aws_vpc.this.id
  ingress { from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = [var.cidr] }
  egress  { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  vpc_id      = aws_vpc.this.id
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

locals {
  interface_endpoints = [
    "bedrock-runtime", "bedrock-agentcore", "ecr.api", "ecr.dkr",
    "logs", "sts", "secretsmanager"
  ]
}

resource "aws_vpc_endpoint" "gateway_s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

data "aws_region" "current" {}
```
> Verify each interface endpoint service name exists in `us-east-1` with `aws ec2 describe-vpc-endpoint-services --query 'ServiceNames' | grep <name>`. If `bedrock-agentcore` is not yet a PrivateLink service in your region, remove it from `local.interface_endpoints` and note it in the runbook (the agent then reaches AgentCore over the NAT path).

- [ ] **Step 2: Append outputs**

```hcl
output "app_sg_id"       { value = aws_security_group.app.id }
output "endpoint_sg_id"  { value = aws_security_group.endpoints.id }
```

- [ ] **Step 3: Validate + plan + commit**

Run: `make fmt && make validate && make plan`
Expected: plan adds the S3 gateway endpoint + interface endpoints + 2 SGs.
```bash
git add terraform/modules/network
git commit -m "feat(infra): VPC endpoints (PrivateLink) + security groups"
```

---

## Phase 2 — Security (KMS) & Storage (S3)

### Task 2.1: `security` module — KMS CMK

**Files:**
- Create: `terraform/modules/security/main.tf`, `variables.tf`, `outputs.tf`

- [ ] **Step 1: `variables.tf`**

```hcl
variable "name" { type = string }
```

- [ ] **Step 2: `main.tf`**

```hcl
resource "aws_kms_key" "this" {
  description             = "${var.name} CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}
resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
```

- [ ] **Step 3: `outputs.tf`**

```hcl
output "kms_key_arn" { value = aws_kms_key.this.arn }
output "kms_key_id"  { value = aws_kms_key.this.key_id }
```

- [ ] **Step 4: Wire into root + validate + plan + commit**

Add to `terraform/main.tf`:
```hcl
module "security" {
  source = "./modules/security"
  name   = "genai-ka-${var.env}"
}
```
Run: `make fmt && make validate && make plan` (expect KMS key + alias).
```bash
git add terraform/modules/security terraform/main.tf
git commit -m "feat(infra): KMS CMK module"
```

### Task 2.2: `storage` module — S3 docs bucket

**Files:**
- Create: `terraform/modules/storage/main.tf`, `variables.tf`, `outputs.tf`

- [ ] **Step 1: `variables.tf`**

```hcl
variable "name"        { type = string }
variable "kms_key_arn" { type = string }
```

- [ ] **Step 2: `main.tf`**

```hcl
resource "aws_s3_bucket" "docs" { bucket = "${var.name}-docs" }

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}
resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- [ ] **Step 3: `outputs.tf`**

```hcl
output "docs_bucket"     { value = aws_s3_bucket.docs.bucket }
output "docs_bucket_arn" { value = aws_s3_bucket.docs.arn }
```

- [ ] **Step 4: Wire into root + validate + plan + commit**

Add to `terraform/main.tf`:
```hcl
module "storage" {
  source      = "./modules/storage"
  name        = "genai-ka-${var.env}"
  kms_key_arn = module.security.kms_key_arn
}
```
Run: `make fmt && make validate && make plan` (expect bucket + versioning + SSE + PAB).
```bash
git add terraform/modules/storage terraform/main.tf
git commit -m "feat(infra): S3 docs bucket (versioned, SSE-KMS, no public access)"
```

### Task 2.3: First deploy + verify foundation

- [ ] **Step 1: Apply**

Run: `make apply`
Expected: apply completes; VPC, endpoints, KMS, S3 created.

- [ ] **Step 2: Verify**

Run:
```bash
aws s3 ls | grep genai-ka-dev-docs
aws ec2 describe-vpc-endpoints --query "VpcEndpoints[].ServiceName" --output text
```
Expected: docs bucket listed; interface + gateway endpoints present.

- [ ] **Step 3: Commit (state is remote; nothing to commit unless tfvars changed).** Note success in `docs/runbook.md` (create the file with a "Deploy log" heading).

```bash
git add docs/runbook.md
git commit -m "docs: start runbook with foundation deploy log"
```

---

## Phase 3 — Knowledge Base (RAG)

### Task 3.1: Sample documents

**Files:**
- Create: `data/hr-policy.md`, `data/it-security-policy.md`, `data/product-faq.md`

- [ ] **Step 1: Create three short, realistic policy/FAQ docs** (≥ 200 words each so retrieval is meaningful). Example `data/hr-policy.md`:

```markdown
# Acme Corp HR Policy

## Paid Time Off
Full-time employees accrue 20 days of paid time off (PTO) per year...
## Remote Work
Employees may work remotely up to 3 days per week with manager approval...
## Expense Reimbursement
Submit expenses within 30 days via the finance portal...
```
(Write equivalently substantive content for the IT security policy and product FAQ.)

- [ ] **Step 2: Commit**

```bash
git add data/
git commit -m "feat: sample knowledge-base documents"
```

### Task 3.2: `knowledge_base` module — OpenSearch Serverless collection + index

**Files:**
- Create: `terraform/modules/knowledge_base/main.tf`, `variables.tf`, `outputs.tf`

- [ ] **Step 1: `variables.tf`**

```hcl
variable "name"               { type = string }
variable "kms_key_arn"        { type = string }
variable "docs_bucket_arn"    { type = string }
variable "embedding_model_id" { type = string }
variable "region"             { type = string }
```

- [ ] **Step 2: `main.tf` — collection + access/security policies**

```hcl
data "aws_caller_identity" "me" {}

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${var.name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules      = [{ ResourceType = "collection", Resource = ["collection/${var.name}"] }]
    AWSOwnedKey = true
  })
}
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${var.name}-net"
  type = "network"
  policy = jsonencode([{
    Rules = [
      { ResourceType = "collection", Resource = ["collection/${var.name}"] },
      { ResourceType = "dashboard",  Resource = ["collection/${var.name}"] }
    ]
    AllowFromPublic = true
  }])
}
resource "aws_opensearchserverless_collection" "kb" {
  name = var.name
  type = "VECTORSEARCH"
  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}
resource "aws_opensearchserverless_access_policy" "kb" {
  name = "${var.name}-access"
  type = "data"
  policy = jsonencode([{
    Rules = [
      { ResourceType = "index",      Resource = ["index/${var.name}/*"], Permission = ["aoss:*"] },
      { ResourceType = "collection", Resource = ["collection/${var.name}"], Permission = ["aoss:*"] }
    ]
    Principal = [data.aws_caller_identity.me.arn, aws_iam_role.kb.arn]
  }])
}
```

- [ ] **Step 3: Validate + plan + commit** (index + KB added next task)

Run: `make fmt && make validate` (plan will fail until `aws_iam_role.kb` exists — add it in Step of next task; for now comment the `Principal` line referencing the role, validate, then uncomment after Task 3.3 Step 1). Commit after validate passes:
```bash
git add terraform/modules/knowledge_base
git commit -m "feat(infra): OpenSearch Serverless collection + policies"
```

### Task 3.3: `knowledge_base` — ingestion IAM role, vector index, Bedrock KB + data source

**Files:**
- Modify: `terraform/modules/knowledge_base/main.tf`, `outputs.tf`

- [ ] **Step 1: Append KB ingestion role**

```hcl
resource "aws_iam_role" "kb" {
  name = "${var.name}-kb-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "bedrock.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "kb" {
  role = aws_iam_role.kb.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["aoss:APIAccessAll"], Resource = aws_opensearchserverless_collection.kb.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [var.docs_bucket_arn, "${var.docs_bucket_arn}/*"] },
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "arn:aws:bedrock:${var.region}::foundation-model/${var.embedding_model_id}" }
    ]
  })
}
```

- [ ] **Step 2: Create the vector index** (provider lacks a first-class AOSS index resource for KBs in some versions — use a null_resource that calls the AOSS API, OR the `opensearch` provider. Confirm via context7. The robust path is an index-creation script.)

Create `terraform/modules/knowledge_base/index.tf`:
```hcl
resource "terraform_data" "index" {
  depends_on = [aws_opensearchserverless_access_policy.kb]
  provisioner "local-exec" {
    command = "python ${path.module}/create_index.py ${aws_opensearchserverless_collection.kb.collection_endpoint} ${var.name} ${var.region}"
  }
}
# IAM/data-access policy propagation delay before KB creation (documented gotcha)
resource "time_sleep" "wait_iam" {
  depends_on      = [aws_iam_role_policy.kb, terraform_data.index]
  create_duration = "30s"
}
```
Create `terraform/modules/knowledge_base/create_index.py` (uses `opensearch-py` + SigV4 to PUT an index named `<name>` with a `knn_vector` field `vector` of dimension 1024, plus `text` and `metadata` fields). Include a docstring and exit non-zero on failure.

- [ ] **Step 3: Append Bedrock KB + data source**

```hcl
resource "aws_bedrockagent_knowledge_base" "this" {
  name     = var.name
  role_arn = aws_iam_role.kb.arn
  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.region}::foundation-model/${var.embedding_model_id}"
    }
  }
  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = var.name
      field_mapping {
        vector_field   = "vector"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }
  depends_on = [time_sleep.wait_iam]
}
resource "aws_bedrockagent_data_source" "s3" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
  name              = "${var.name}-s3"
  data_source_configuration {
    type = "S3"
    s3_configuration { bucket_arn = var.docs_bucket_arn }
  }
}
```
> Verify `aws_bedrockagent_knowledge_base` nested block names against your provider version via context7 before applying.

- [ ] **Step 4: Outputs**

```hcl
output "knowledge_base_id" { value = aws_bedrockagent_knowledge_base.this.id }
output "data_source_id"    { value = aws_bedrockagent_data_source.s3.id }
output "kb_role_arn"       { value = aws_iam_role.kb.arn }
```

- [ ] **Step 5: Wire into root + validate + plan + commit**

Add to `terraform/main.tf`:
```hcl
module "knowledge_base" {
  source             = "./modules/knowledge_base"
  name               = "genai-ka-${var.env}"
  kms_key_arn        = module.security.kms_key_arn
  docs_bucket_arn    = module.storage.docs_bucket_arn
  embedding_model_id = var.embedding_model_id
  region             = var.region
}
```
Run: `make fmt && make validate && make plan`.
```bash
git add terraform/modules/knowledge_base terraform/main.tf
git commit -m "feat(infra): Bedrock Knowledge Base on OpenSearch Serverless"
```

### Task 3.4: Ingestion script + deploy + verify RAG

**Files:**
- Create: `scripts/ingest.py`

- [ ] **Step 1: Write `scripts/ingest.py`** — uploads `data/*.md` to the docs bucket (key prefix `docs/`), then calls `bedrock-agent start_ingestion_job` for the KB+data source, polls until `COMPLETE`. Read bucket/KB/DS IDs from `terraform output -json`.

```python
import json, subprocess, sys, time, boto3, pathlib

def tf_out():
    return json.loads(subprocess.check_output(
        ["terraform", "-chdir=terraform", "output", "-json"]))

def main():
    o = tf_out()
    bucket = o["docs_bucket"]["value"]
    kb = o["knowledge_base_id"]["value"]
    ds = o["data_source_id"]["value"]
    s3 = boto3.client("s3"); agent = boto3.client("bedrock-agent")
    for f in pathlib.Path("data").glob("*.md"):
        s3.upload_file(str(f), bucket, f"docs/{f.name}")
        print("uploaded", f.name)
    job = agent.start_ingestion_job(knowledgeBaseId=kb, dataSourceId=ds)["ingestionJob"]["ingestionJobId"]
    while True:
        st = agent.get_ingestion_job(knowledgeBaseId=kb, dataSourceId=ds, ingestionJobId=job)["ingestionJob"]["status"]
        print("ingestion:", st)
        if st in ("COMPLETE", "FAILED"): break
        time.sleep(10)
    sys.exit(0 if st == "COMPLETE" else 1)

if __name__ == "__main__": main()
```

- [ ] **Step 2: Apply + ingest**

Run: `make apply && python scripts/ingest.py`
Expected: `ingestion: COMPLETE`.

- [ ] **Step 3: Verify retrieval**

Run:
```bash
KB=$(terraform -chdir=terraform output -raw knowledge_base_id)
aws bedrock-agent-runtime retrieve --knowledge-base-id $KB \
  --retrieval-query '{"text":"how many PTO days do employees get?"}' \
  --query 'retrievalResults[0].content.text' --output text
```
Expected: text mentioning "20 days" of PTO.

- [ ] **Step 4: Commit**

```bash
git add scripts/ingest.py
git commit -m "feat: KB ingestion script + verified retrieval"
```

---

## Phase 4 — Lambda tool

### Task 4.1: `create_ticket` Lambda (TDD)

**Files:**
- Create: `services/lambda_tool/handler.py`, `services/lambda_tool/tests/test_handler.py`, `services/lambda_tool/requirements.txt`

- [ ] **Step 1: Write the failing test** `services/lambda_tool/tests/test_handler.py`

```python
import os, boto3, pytest
from moto import mock_aws
from services.lambda_tool import handler

@mock_aws
def test_create_ticket_writes_item_and_returns_id():
    os.environ["TICKETS_TABLE"] = "tickets"
    ddb = boto3.resource("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="tickets",
        KeySchema=[{"AttributeName": "ticket_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "ticket_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    event = {"subject": "VPN broken", "description": "cannot connect", "requester": "joe"}
    result = handler.create_ticket(event)
    assert result["status"] == "created"
    assert result["ticket_id"].startswith("TKT-")
    item = ddb.Table("tickets").get_item(Key={"ticket_id": result["ticket_id"]})["Item"]
    assert item["subject"] == "VPN broken"
```

- [ ] **Step 2: Run test — expect fail**

Run: `pip install moto boto3 pytest && pytest services/lambda_tool/tests/test_handler.py -v`
Expected: FAIL (`handler` has no `create_ticket`).

- [ ] **Step 3: Implement** `services/lambda_tool/handler.py`

```python
import os, uuid, datetime, boto3

def create_ticket(event: dict) -> dict:
    table = boto3.resource("dynamodb").Table(os.environ["TICKETS_TABLE"])
    ticket_id = f"TKT-{uuid.uuid4().hex[:8].upper()}"
    item = {
        "ticket_id": ticket_id,
        "subject": event.get("subject", ""),
        "description": event.get("description", ""),
        "requester": event.get("requester", "unknown"),
        "created_at": datetime.datetime.utcnow().isoformat() + "Z",
        "status": "open",
    }
    table.put_item(Item=item)
    return {"status": "created", "ticket_id": ticket_id}

def lambda_handler(event, context):
    # AgentCore Gateway (Lambda target) passes tool args as the event payload.
    return create_ticket(event)
```

- [ ] **Step 4: Run test — expect pass**

Run: `pytest services/lambda_tool/tests/test_handler.py -v`
Expected: PASS.

- [ ] **Step 5: requirements + commit**

Create `services/lambda_tool/requirements.txt` with `boto3`.
```bash
git add services/lambda_tool
git commit -m "feat(tool): create_ticket lambda + tests"
```

### Task 4.2: `tool` module — Lambda + DynamoDB + IAM

**Files:**
- Create: `terraform/modules/tool/main.tf`, `variables.tf`, `outputs.tf`

- [ ] **Step 1: `variables.tf`**

```hcl
variable "name"        { type = string }
variable "kms_key_arn" { type = string }
```

- [ ] **Step 2: `main.tf`**

```hcl
resource "aws_dynamodb_table" "tickets" {
  name         = "${var.name}-tickets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ticket_id"
  attribute { name = "ticket_id"; type = "S" }
  server_side_encryption { enabled = true, kms_key_arn = var.kms_key_arn }
}

data "archive_file" "tool" {
  type        = "zip"
  source_dir  = "${path.root}/../services/lambda_tool"
  output_path = "${path.module}/tool.zip"
}

resource "aws_iam_role" "tool" {
  name = "${var.name}-tool-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "tool_basic" {
  role       = aws_iam_role.tool.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "tool" {
  role = aws_iam_role.tool.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:GetItem"], Resource = aws_dynamodb_table.tickets.arn },
      { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = var.kms_key_arn }
    ]
  })
}

resource "aws_lambda_function" "tool" {
  function_name    = "${var.name}-create-ticket"
  role             = aws_iam_role.tool.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.tool.output_path
  source_code_hash = data.archive_file.tool.output_base64sha256
  timeout          = 30
  environment { variables = { TICKETS_TABLE = aws_dynamodb_table.tickets.name } }
}
```

- [ ] **Step 3: `outputs.tf`**

```hcl
output "tool_lambda_arn"  { value = aws_lambda_function.tool.arn }
output "tool_lambda_name" { value = aws_lambda_function.tool.function_name }
```

- [ ] **Step 4: Wire into root + validate + plan + apply + verify**

Add to `terraform/main.tf`:
```hcl
module "tool" {
  source      = "./modules/tool"
  name        = "genai-ka-${var.env}"
  kms_key_arn = module.security.kms_key_arn
}
```
Run: `make fmt && make validate && make plan && make apply`
Verify:
```bash
FN=$(terraform -chdir=terraform output -raw tool_lambda_name)
aws lambda invoke --function-name $FN --payload '{"subject":"test","description":"d","requester":"me"}' /tmp/out.json
cat /tmp/out.json
```
Expected: `{"status":"created","ticket_id":"TKT-..."}`.

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/tool terraform/main.tf
git commit -m "feat(infra): create_ticket lambda + dynamodb + IAM"
```

---

## Phase 5 — Agent (AgentCore Runtime + Gateway + Memory + Identity)

> Every AgentCore resource below: confirm exact argument schema via context7 / Terraform Registry against your pinned provider before applying. Shapes are correct; field names may differ slightly by version.

### Task 5.1: Agent application code (TDD on the tool-calling helper)

**Files:**
- Create: `services/agent/agent.py`, `services/agent/tests/test_agent.py`, `services/agent/requirements.txt`, `services/agent/Dockerfile`

- [ ] **Step 1: Failing test** `services/agent/tests/test_agent.py` — tests a pure helper `build_system_prompt(kb_id)` that embeds RAG instructions and the KB id.

```python
from services.agent.agent import build_system_prompt

def test_system_prompt_mentions_kb_and_tool():
    p = build_system_prompt("KB123")
    assert "KB123" in p
    assert "create_ticket" in p
    assert "knowledge base" in p.lower()
```

- [ ] **Step 2: Run — expect fail**

Run: `pytest services/agent/tests/test_agent.py -v` → FAIL.

- [ ] **Step 3: Implement `services/agent/agent.py`**

```python
"""RAG agent hosted on AgentCore Runtime (Strands + Bedrock)."""
import os
from strands import Agent
from strands.models import BedrockModel
from bedrock_agentcore.runtime import BedrockAgentCoreApp

def build_system_prompt(kb_id: str) -> str:
    return (
        "You are an enterprise knowledge assistant. Answer questions using the "
        f"company knowledge base (id: {kb_id}). Always ground answers in retrieved "
        "context and cite the source document. If the user wants to report a problem, "
        "call the create_ticket tool. Do not invent facts."
    )

app = BedrockAgentCoreApp()
_agent = Agent(
    model=BedrockModel(model_id=os.environ["AGENT_MODEL_ID"]),
    system_prompt=build_system_prompt(os.environ.get("KNOWLEDGE_BASE_ID", "")),
)

@app.entrypoint
def invoke(payload: dict):
    return _agent(payload.get("prompt", ""))

if __name__ == "__main__":
    app.run()
```

- [ ] **Step 4: Run — expect pass**

Run: `pip install strands-agents bedrock-agentcore && pytest services/agent/tests/test_agent.py -v`
Expected: PASS. (If the import path of `BedrockAgentCoreApp` differs in the installed SDK version, fix the import — confirm via `python -c "import bedrock_agentcore"` and the SDK README.)

- [ ] **Step 5: Dockerfile** `services/agent/Dockerfile`

```dockerfile
FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY agent.py .
EXPOSE 8080
CMD ["python", "agent.py"]
```
`requirements.txt`: `strands-agents`, `bedrock-agentcore`, `boto3`.

- [ ] **Step 6: Commit**

```bash
git add services/agent
git commit -m "feat(agent): RAG agent app + system prompt test + Dockerfile"
```

### Task 5.2: `agent` module — ECR repo + build/push script

**Files:**
- Create: `terraform/modules/agent/ecr.tf`, `variables.tf`, `outputs.tf`, `scripts/build_push.sh`

- [ ] **Step 1: `variables.tf`**

```hcl
variable "name"               { type = string }
variable "region"             { type = string }
variable "agent_model_id"     { type = string }
variable "knowledge_base_id"  { type = string }
variable "kb_arn"             { type = string }
variable "tool_lambda_arn"    { type = string }
variable "kms_key_arn"        { type = string }
```

- [ ] **Step 2: `ecr.tf`**

```hcl
resource "aws_ecr_repository" "agent" {
  name                 = "${var.name}-agent"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS", kms_key = var.kms_key_arn }
}
output "agent_repo_url" { value = aws_ecr_repository.agent.repository_url }
```

- [ ] **Step 3: `scripts/build_push.sh`** — builds `services/agent` for `linux/arm64` (AgentCore Runtime requirement — verify in docs), logs into ECR, pushes `:latest`, prints the image URI.

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO=$(terraform -chdir=terraform output -raw agent_repo_url)
REGION=us-east-1
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "${REPO%/*}"
docker build --platform linux/arm64 -t "$REPO:latest" services/agent
docker push "$REPO:latest"
echo "$REPO:latest"
```

- [ ] **Step 4: Wire ECR into root (partial module), validate, plan, apply ECR only, build/push**

Add module block (only ECR outputs used so far) to `terraform/main.tf`, `make apply`, then:
Run: `bash scripts/build_push.sh`
Expected: image pushed; final line is the image URI.

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/agent scripts/build_push.sh terraform/main.tf
git commit -m "feat(infra): agent ECR repo + build/push script"
```

### Task 5.3: `agent` module — AgentCore Memory

**Files:**
- Create: `terraform/modules/agent/memory.tf`

- [ ] **Step 1: `memory.tf`**

```hcl
resource "aws_bedrockagentcore_memory" "this" {
  name = "${var.name}-memory"
  # short-term memory only for the demo; long-term documented as extension
}
output "memory_id" { value = aws_bedrockagentcore_memory.this.id }
```
> Confirm required args (e.g. event/expiry settings) for `aws_bedrockagentcore_memory` via context7 before plan.

- [ ] **Step 2: Validate + plan + commit**

Run: `make fmt && make validate && make plan`.
```bash
git add terraform/modules/agent/memory.tf
git commit -m "feat(infra): AgentCore Memory (short-term)"
```

### Task 5.4: `agent` module — Identity (Cognito) + agent execution role

**Files:**
- Create: `terraform/modules/agent/identity.tf`, `iam.tf`

- [ ] **Step 1: `identity.tf`** — Cognito user pool + app client used both as inbound auth for the agent and the UI.

```hcl
resource "aws_cognito_user_pool" "this" { name = "${var.name}-users" }
resource "aws_cognito_user_pool_client" "this" {
  name            = "${var.name}-client"
  user_pool_id    = aws_cognito_user_pool.this.id
  generate_secret = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  allowed_oauth_flows_user_pool_client = true
  callback_urls                        = ["https://example.com/callback"] # replaced with ALB DNS in Phase 6
  supported_identity_providers         = ["COGNITO"]
}
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.name}-${data.aws_caller_identity.cur.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}
data "aws_caller_identity" "cur" {}
output "user_pool_id"        { value = aws_cognito_user_pool.this.id }
output "user_pool_client_id" { value = aws_cognito_user_pool_client.this.id }
output "cognito_domain"      { value = aws_cognito_user_pool_domain.this.domain }
```

- [ ] **Step 2: `iam.tf`** — agent runtime execution role (Bedrock invoke + KB retrieve + Gateway + Memory).

```hcl
resource "aws_iam_role" "agent" {
  name = "${var.name}-agent-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "bedrock-agentcore.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "agent" {
  role = aws_iam_role.agent.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"], Resource = "arn:aws:bedrock:${var.region}::foundation-model/${var.agent_model_id}" },
      { Effect = "Allow", Action = ["bedrock:Retrieve"], Resource = var.kb_arn },
      { Effect = "Allow", Action = ["bedrock-agentcore:*"], Resource = "*" },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }
    ]
  })
}
output "agent_role_arn" { value = aws_iam_role.agent.arn }
```
> Tighten `bedrock-agentcore:*` to specific actions (Gateway invoke, Memory read/write) once you confirm the action names — note this as a hardening TODO in the runbook.

- [ ] **Step 3: Validate + plan + commit**

Run: `make fmt && make validate && make plan`.
```bash
git add terraform/modules/agent/identity.tf terraform/modules/agent/iam.tf
git commit -m "feat(infra): Cognito identity + agent execution role"
```

### Task 5.5: `agent` module — Gateway + Lambda target

**Files:**
- Create: `terraform/modules/agent/gateway.tf`

- [ ] **Step 1: `gateway.tf`**

```hcl
resource "aws_bedrockagentcore_gateway" "this" {
  name = "${var.name}-gateway"
  role_arn = aws_iam_role.agent.arn
  protocol_type = "MCP"
  authorizer_type = "CUSTOM_JWT"
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this.id}/.well-known/openid-configuration"
      allowed_clients = [aws_cognito_user_pool_client.this.id]
    }
  }
}
resource "aws_bedrockagentcore_gateway_target" "ticket" {
  gateway_identifier = aws_bedrockagentcore_gateway.this.id
  name               = "create-ticket"
  target_configuration {
    mcp {
      lambda {
        lambda_arn = var.tool_lambda_arn
        tool_schema {
          inline = jsonencode([{
            name        = "create_ticket"
            description = "Create a support ticket from a subject, description, and requester."
            inputSchema = {
              type = "object"
              properties = {
                subject     = { type = "string" }
                description = { type = "string" }
                requester   = { type = "string" }
              }
              required = ["subject", "description"]
            }
          }])
        }
      }
    }
  }
}
resource "aws_lambda_permission" "gateway" {
  statement_id  = "AllowAgentCoreGateway"
  action        = "lambda:InvokeFunction"
  function_name = var.tool_lambda_arn
  principal     = "bedrock-agentcore.amazonaws.com"
}
output "gateway_url" { value = aws_bedrockagentcore_gateway.this.gateway_url }
```
> The `target_configuration`/`tool_schema` nesting is the highest-risk schema in this plan — verify against the registry/context7 and the `gateway-supported-targets` doc before plan. Adjust block names to match the provider.

- [ ] **Step 2: Validate + plan + commit**

Run: `make fmt && make validate && make plan`.
```bash
git add terraform/modules/agent/gateway.tf
git commit -m "feat(infra): AgentCore Gateway + create_ticket Lambda target"
```

### Task 5.6: `agent` module — Runtime + endpoint

**Files:**
- Create: `terraform/modules/agent/runtime.tf`

- [ ] **Step 1: `runtime.tf`**

```hcl
variable "agent_image_uri" { type = string }

resource "aws_bedrockagentcore_agent_runtime" "this" {
  name     = "${var.name}_runtime"
  role_arn = aws_iam_role.agent.arn
  agent_runtime_artifact {
    container_configuration { container_uri = var.agent_image_uri }
  }
  network_configuration { network_mode = "PUBLIC" } # switch to VPC config once endpoints verified
  environment_variables = {
    AGENT_MODEL_ID    = var.agent_model_id
    KNOWLEDGE_BASE_ID = var.knowledge_base_id
    GATEWAY_URL       = aws_bedrockagentcore_gateway.this.gateway_url
    MEMORY_ID         = aws_bedrockagentcore_memory.this.id
  }
}
resource "aws_bedrockagentcore_runtime_endpoint" "this" {
  agent_runtime_id = aws_bedrockagentcore_agent_runtime.this.id
  name             = "default"
}
output "agent_runtime_arn"      { value = aws_bedrockagentcore_agent_runtime.this.id }
output "agent_runtime_endpoint" { value = aws_bedrockagentcore_runtime_endpoint.this.id }
```
> Confirm `agent_runtime_artifact` / `network_configuration` schema and whether ARM64 image is required, via context7. Pass `agent_image_uri` from the root using the pushed image URI (Task 5.2).

- [ ] **Step 2: Finalize root wiring for `agent` module**

In `terraform/main.tf`, complete the module call:
```hcl
module "agent" {
  source            = "./modules/agent"
  name              = "genai-ka-${var.env}"
  region            = var.region
  agent_model_id    = var.agent_model_id
  knowledge_base_id = module.knowledge_base.knowledge_base_id
  kb_arn            = "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.root.account_id}:knowledge-base/${module.knowledge_base.knowledge_base_id}"
  tool_lambda_arn   = module.tool.tool_lambda_arn
  kms_key_arn       = module.security.kms_key_arn
  agent_image_uri   = var.agent_image_uri
}
data "aws_caller_identity" "root" {}
```
Add `variable "agent_image_uri" { type = string }` to root `variables.tf` and set it in `dev.tfvars` to the URI from `build_push.sh`.

- [ ] **Step 3: Validate + plan + apply + verify agent**

Run: `make fmt && make validate && make plan && make apply`
Verify:
```bash
ARN=$(terraform -chdir=terraform output -raw agent_runtime_arn)
aws bedrock-agentcore invoke-agent-runtime --agent-runtime-arn "$ARN" \
  --payload '{"prompt":"How many PTO days do I get?"}' /tmp/agent.json || \
  echo "If CLI shape differs, use scripts/smoke_test.py (Phase 7)"
```
Expected: a grounded answer mentioning PTO days. Troubleshoot per runbook if AccessDenied (IAM trust) or timeout (networking).

- [ ] **Step 4: Commit**

```bash
git add terraform/modules/agent/runtime.tf terraform/main.tf terraform/variables.tf terraform/dev.tfvars
git commit -m "feat(infra): AgentCore Runtime + endpoint; agent end-to-end"
```

---

## Phase 6 — App (ECS Fargate UI + ALB + WAF)

### Task 6.1: FastAPI UI (TDD on the agent-client)

**Files:**
- Create: `services/ui/app.py`, `services/ui/agent_client.py`, `services/ui/tests/test_agent_client.py`, `services/ui/templates/index.html`, `services/ui/Dockerfile`, `services/ui/requirements.txt`

- [ ] **Step 1: Failing test** `services/ui/tests/test_agent_client.py`

```python
from services.ui.agent_client import parse_agent_response

def test_parse_agent_response_extracts_text():
    raw = {"output": {"message": {"content": [{"text": "You get 20 PTO days."}]}}}
    assert parse_agent_response(raw) == "You get 20 PTO days."

def test_parse_agent_response_handles_plain_text():
    assert parse_agent_response("hello") == "hello"
```

- [ ] **Step 2: Run — expect fail**

Run: `pytest services/ui/tests/test_agent_client.py -v` → FAIL.

- [ ] **Step 3: Implement `services/ui/agent_client.py`**

```python
import json, os, boto3

def parse_agent_response(raw) -> str:
    if isinstance(raw, str):
        return raw
    try:
        return raw["output"]["message"]["content"][0]["text"]
    except (KeyError, IndexError, TypeError):
        return json.dumps(raw)

def invoke_agent(prompt: str) -> str:
    client = boto3.client("bedrock-agentcore")
    resp = client.invoke_agent_runtime(
        agentRuntimeArn=os.environ["AGENT_RUNTIME_ARN"],
        payload=json.dumps({"prompt": prompt}).encode(),
    )
    body = resp["response"].read() if hasattr(resp["response"], "read") else resp["response"]
    return parse_agent_response(json.loads(body))
```
> Confirm `invoke_agent_runtime` request/response shape via context7 / boto3 docs; adjust keys if needed (the parsing test stays valid regardless).

- [ ] **Step 4: Run — expect pass**

Run: `pytest services/ui/tests/test_agent_client.py -v` → PASS.

- [ ] **Step 5: `app.py` + `index.html` + Dockerfile + requirements**

`app.py` — FastAPI with `GET /` (render chat form) and `POST /ask` (call `invoke_agent`, render answer) and `GET /healthz` returning `{"ok": true}`. `requirements.txt`: `fastapi`, `uvicorn[standard]`, `jinja2`, `boto3`. Dockerfile mirrors the agent's (CMD `uvicorn app:app --host 0.0.0.0 --port 8080`).

- [ ] **Step 6: Commit**

```bash
git add services/ui
git commit -m "feat(ui): FastAPI chat UI + agent client + tests"
```

### Task 6.2: `app` module — ECS Fargate + ALB + WAF

**Files:**
- Create: `terraform/modules/app/main.tf`, `variables.tf`, `outputs.tf`; `scripts/build_push_ui.sh`

- [ ] **Step 1: `variables.tf`** — `name`, `region`, `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `app_sg_id`, `agent_runtime_arn`, `kms_key_arn`, `ui_image_uri`.

- [ ] **Step 2: `main.tf`** — ECR repo for UI; ECS cluster; task definition (Fargate, arm64, env `AGENT_RUNTIME_ARN`); task role allowing `bedrock-agentcore:InvokeAgentRuntime`; ALB in public subnets + target group + listener; ECS service in private subnets; WAFv2 web ACL (AWS managed common rules) associated to the ALB; security group rules (ALB:443→service:8080). Health check path `/healthz`.

(Write the full HCL following the patterns from earlier modules: `aws_ecr_repository`, `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_iam_role` (task + exec), `aws_lb`, `aws_lb_target_group`, `aws_lb_listener`, `aws_ecs_service`, `aws_wafv2_web_acl`, `aws_wafv2_web_acl_association`, `aws_security_group_rule`.)

- [ ] **Step 3: `outputs.tf`**

```hcl
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "ui_repo_url"  { value = aws_ecr_repository.ui.repository_url }
```

- [ ] **Step 4: Wire root, apply ECR, build/push UI image, set `ui_image_uri`, apply rest, verify**

Run: `make apply` (ECR) → `bash scripts/build_push_ui.sh` → set `ui_image_uri` in `dev.tfvars` → `make apply`.
Verify:
```bash
curl -s http://$(terraform -chdir=terraform output -raw alb_dns_name)/healthz
```
Expected: `{"ok":true}`. Then open the ALB DNS in a browser, ask a question, confirm a grounded answer; ask to "open a ticket about VPN" and confirm a `TKT-` id appears.

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/app scripts/build_push_ui.sh terraform/main.tf terraform/dev.tfvars
git commit -m "feat(infra): ECS Fargate UI + ALB + WAF; UI end-to-end"
```

---

## Phase 7 — Observability

### Task 7.1: `observability` module — logs, dashboard, alarms, X-Ray

**Files:**
- Create: `terraform/modules/observability/main.tf`, `variables.tf`, `outputs.tf`

- [ ] **Step 1: `variables.tf`** — `name`, `region`, `agent_runtime_id`, `tool_lambda_name`, `alarm_email`.

- [ ] **Step 2: `main.tf`** — SNS topic + email subscription; CloudWatch log groups (retention 14d, KMS); `aws_cloudwatch_dashboard` with widgets for AgentCore session count/latency/errors/token usage (namespace `AWS/BedrockAgentCore` — verify metric names in the AgentCore Observability console), Lambda invocations/errors/duration, and KB retrieval count; alarms on Lambda `Errors > 0` and agent error-rate → SNS. Enable X-Ray (note: agent tracing is built-in via AgentCore Observability; the UI/Lambda get X-Ray via SDK + `tracing_config`).

(Write full HCL; for metric names not yet confirmed, add a comment to verify in the CloudWatch console and adjust.)

- [ ] **Step 3: Wire root + apply + verify**

Run: `make apply`. Open CloudWatch → Dashboards → `genai-ka-dev`. Confirm widgets render after generating traffic (ask a few questions in the UI). Confirm the AgentCore Observability trace view shows agent steps + the tool call.

- [ ] **Step 4: Commit**

```bash
git add terraform/modules/observability terraform/main.tf
git commit -m "feat(infra): CloudWatch dashboard, alarms, X-Ray, SNS"
```

---

## Phase 8 — Quality, automation & docs

### Task 8.1: End-to-end smoke test

**Files:**
- Create: `scripts/smoke_test.py`

- [ ] **Step 1: Write `scripts/smoke_test.py`** — reads `terraform output`, then: (a) hits `/healthz` on the ALB, (b) POSTs a RAG question to `/ask` and asserts the answer contains an expected keyword (e.g. "20"), (c) invokes the agent runtime directly with a "create a ticket" prompt and asserts a DynamoDB item appears. Exit non-zero on any failure, print a clear PASS/FAIL summary.

- [ ] **Step 2: Run**

Run: `python scripts/smoke_test.py`
Expected: `SMOKE: PASS` and exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke_test.py
git commit -m "test: end-to-end smoke test"
```

### Task 8.2: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write `ci.yml`** — on PR: setup Python + Terraform + tflint; run `pytest`, `terraform fmt -check`, `terraform -chdir=terraform validate`, `tflint`, and `terraform -chdir=terraform plan` (using OIDC role assumption; for the demo, plan can run with read-only creds or be allowed to fail gracefully if no creds — guard with `continue-on-error` and a comment). Keep `apply` manual.

- [ ] **Step 2: Validate YAML locally** (`yamllint` or push to a branch and open a PR). Commit.

```bash
git add .github/workflows/ci.yml
git commit -m "ci: fmt/validate/tflint/plan + pytest on PRs"
```

### Task 8.3: Documentation

**Files:**
- Create/expand: `README.md`, `docs/architecture.md`, `docs/integration-guide.md`, `docs/runbook.md`

- [ ] **Step 1: `README.md`** — what it is, architecture diagram (reuse the spec's ASCII diagram), prerequisites, quickstart (`make demo`), cost note + `make destroy`, screenshots placeholder.

- [ ] **Step 2: `docs/architecture.md`** — component responsibilities + key decisions (why AgentCore Runtime over Harness, why OpenSearch Serverless), referencing `docs/agentcore-enterprise-bottlenecks.md`.

- [ ] **Step 3: `docs/integration-guide.md`** — the exact wiring + data contracts: which Terraform output feeds which module input (network→app, security→all, KB→agent, tool→gateway, agent→app), the Gateway tool schema, the agent payload contract, and the env vars passed to Runtime/ECS.

- [ ] **Step 4: `docs/runbook.md`** — finalize: deploy order, the IAM-propagation delay gotcha, model-access errors, ingestion-stuck, AgentCore AccessDenied (trust policy), networking timeouts (endpoint/SG), how to read the dashboard, rollback (`terraform destroy` of a single target), full teardown.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/
git commit -m "docs: README, architecture, integration guide, runbook"
```

### Task 8.4: Teardown verification

**Files:**
- Create: `scripts/destroy.sh` (wraps `make destroy` + empties S3 buckets + deletes ECR images so destroy succeeds)

- [ ] **Step 1: Write `destroy.sh`** — empty docs bucket + state-data, delete ECR images, then `terraform -chdir=terraform destroy -var-file=dev.tfvars -auto-approve`. (Leave the bootstrap state bucket/lock table intact.)

- [ ] **Step 2: Run + verify**

Run: `bash scripts/destroy.sh`
Expected: destroy completes with no leftover billable resources (verify in Cost Explorer / `aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=genai-ka`).

- [ ] **Step 3: Commit**

```bash
git add scripts/destroy.sh
git commit -m "chore: teardown script (empty buckets/ECR then destroy)"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** Bedrock+AgentCore (Phase 5), end-to-end integration (root wiring + integration-guide Task 8.3), RAG (Phase 3), IaC repeatable deploys (all phases + Makefile + CI Task 8.2), troubleshooting (runbook Task 8.4/8.3 + observability Phase 7), docs/runbooks (Task 8.3), Lambda/S3/ECS/IAM/VPC/CloudWatch (Phases 1,2,4,6,7). Five core AgentCore services: Runtime (5.6), Gateway (5.5), Memory (5.3), Identity/Cognito inbound (5.4), Observability (7.1). ✓
- **Placeholders:** Application code (Lambda, agent helper, UI client) has complete code + tests. Terraform modules that are standard boilerplate (`app`, `observability`) give the explicit resource list + patterns established in earlier full-HCL tasks rather than re-printing 200 lines; AgentCore resources carry explicit "verify schema via context7" gates because the provider is new — this is a deliberate accuracy safeguard, not a placeholder.
- **Type/name consistency:** module outputs → root → downstream module inputs checked (e.g. `knowledge_base_id`, `tool_lambda_arn`, `agent_runtime_arn`, `kms_key_arn`, `app_sg_id`). Lambda `create_ticket` signature matches the Gateway tool schema and the test. ✓

## Known execution risks (call these out to the implementer)

1. **AgentCore provider schemas** — verify every `aws_bedrockagentcore_*` block against the pinned provider before plan; the Gateway target schema (5.5) is highest-risk.
2. **AgentCore Runtime image arch** — likely `linux/arm64`; confirm in the runtime docs before build/push (5.2).
3. **PrivateLink for AgentCore** — if `bedrock-agentcore` isn't a VPC endpoint service in-region yet, drop it (1.2) and rely on NAT; note in runbook.
4. **Region/model IDs** — confirm Claude Sonnet 4.x + Titan v2 exact IDs are enabled in `us-east-1` (0.2 Step 5).
5. **Cost** — OpenSearch Serverless + ECS/ALB are the cost drivers; run `destroy.sh` between demos.
