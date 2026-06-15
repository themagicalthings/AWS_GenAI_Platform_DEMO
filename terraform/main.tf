module "network" {
  source = "./modules/network"
  name   = "genai-ka-${var.env}"
}

module "security" {
  source = "./modules/security"
  name   = "genai-ka-${var.env}"
}
