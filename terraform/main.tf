module "network" {
  source = "./modules/network"
  name   = "genai-ka-${var.env}"
}
