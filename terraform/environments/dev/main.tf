locals {
  name         = "platform-${var.environment}"
  cluster_name = "platform-${var.environment}"
}

module "vpc" {
  source = "../../modules/vpc"

  name                    = local.name
  cidr                    = var.vpc_cidr
  az_count                = 3
  single_nat_gateway      = var.single_nat_gateway
  cluster_name            = local.cluster_name
  flow_log_retention_days = var.log_retention_days
}

module "eks" {
  source = "../../modules/eks"

  name                 = local.cluster_name
  kubernetes_version   = var.kubernetes_version
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  public_access_cidrs  = var.admin_cidrs
  admin_principal_arns = var.cluster_admin_arns

  system_instance_types = var.system_instance_types
  system_min_size       = var.system_min_size
  system_max_size       = var.system_max_size
  system_desired_size   = var.system_desired_size
  log_retention_days    = var.log_retention_days
}

# One registry for the account; images are promoted dev -> staging -> production by tag
module "ecr" {
  source = "../../modules/ecr"

  name = "my-app"
}

module "secrets" {
  source = "../../modules/secrets"

  name                 = local.name
  namespaces           = var.app_namespaces
  recovery_window_days = var.secret_recovery_window_days
}

module "iam" {
  source = "../../modules/iam"

  name                = local.name
  oidc_provider_arn   = module.eks.oidc_provider_arn
  app_namespaces      = var.app_namespaces
  app_secret_arns     = values(module.secrets.secret_arns)
  secrets_kms_key_arn = module.secrets.kms_key_arn
}
