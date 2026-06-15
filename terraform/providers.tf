provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = "genai-ka"
      env     = var.env
      owner   = var.owner
    }
  }
}
