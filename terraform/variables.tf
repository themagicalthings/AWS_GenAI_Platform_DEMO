variable "region" {
  type    = string
  default = "us-east-1"
}
variable "env" {
  type    = string
  default = "dev"
}
variable "owner" {
  type    = string
  default = "thevamsithokala@gmail.com"
}

# Model-id variables (agent_model_id, embedding_model_id) are introduced in the
# phases that consume them: embedding_model_id with the knowledge_base module
# (plan phase 3), agent_model_id with the agent module (plan phase 5). They are
# omitted here to keep tflint's unused-declaration check clean.
