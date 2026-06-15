module "network" {
  source = "./modules/network"
  name   = "genai-ka-${var.env}"
}

module "security" {
  source = "./modules/security"
  name   = "genai-ka-${var.env}"
}

module "storage" {
  source      = "./modules/storage"
  name        = "genai-ka-${var.env}"
  kms_key_arn = module.security.kms_key_arn
}
