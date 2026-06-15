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
variable "agent_model_id" {
  type    = string
  default = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}
variable "embedding_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}
