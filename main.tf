data "aws_availability_zones" "available" {
  state = "available"
}

module "network" {
  source = "./modules/network"

  project  = var.project
  vpc_cidr = var.vpc_cidr
  az_names = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "security" {
  source = "./modules/security"

  project = var.project
  vpc_id  = module.network.vpc_id
}

module "storage" {
  source = "./modules/storage"

  project = var.project
}

module "web" {
  source = "./modules/web"

  project            = var.project
  vpc_id             = module.network.vpc_id
  instance_type      = var.instance_type
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  alb_sg_id          = module.security.alb_sg_id
  web_sg_id          = module.security.web_sg_id
  bucket_arn         = module.storage.bucket_arn
  bucket_name        = module.storage.bucket_name
  min_size           = var.min_size
  max_size           = var.max_size
  desired_capacity   = var.desired_capacity
  cpu_target         = var.cpu_target
}

module "cdn" {
  source = "./modules/cdn"

  project                     = var.project
  alb_dns_name                = module.web.alb_dns_name
  bucket_regional_domain_name = module.storage.bucket_regional_domain_name
  bucket_id                   = module.storage.bucket_id
  bucket_arn                  = module.storage.bucket_arn
}
