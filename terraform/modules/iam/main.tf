# IRSA (IAM Roles for Service Accounts): each workload's Kubernetes service account is mapped to its own
# least-privilege IAM role. A pod gets temporary credentials only if its token comes from this cluster's
# OIDC provider AND names the exact namespace:serviceaccount in the role's trust policy.
# Karpenter's role is added on Day 4.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name" {
  description = "Prefix, e.g. platform-dev"
  type        = string
}

variable "oidc_provider_arn" {
  description = "The EKS cluster's OIDC provider (from the eks module)"
  type        = string
}

variable "app_name" {
  type    = string
  default = "my-app"
}

variable "app_namespaces" {
  type = list(string)
}

variable "app_secret_arns" {
  description = "Secrets the External Secrets Operator may read"
  type        = list(string)
}

variable "secrets_kms_key_arn" {
  type = string
}

# AWS Load Balancer Controller: creates the ALB for each Kubernetes Ingress
module "alb_controller" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.name}-alb-controller"
  use_name_prefix = false

  attach_load_balancer_controller_policy = true # the official policy published by the controller project

  oidc_providers = {
    this = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# External Secrets Operator: reads only the app secrets and decrypts with only their key
module "external_secrets" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.name}-external-secrets"
  use_name_prefix = false

  attach_external_secrets_policy                     = true
  external_secrets_secrets_manager_arns              = var.app_secret_arns
  external_secrets_kms_key_arns                      = [var.secrets_kms_key_arn]
  external_secrets_secrets_manager_create_permission = false

  oidc_providers = {
    this = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

# The application itself: starts with no permissions; add only what the app needs (e.g. one S3 prefix)
module "app" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name            = "${var.name}-${var.app_name}"
  use_name_prefix = false

  oidc_providers = {
    this = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = [for ns in var.app_namespaces : "${ns}:${var.app_name}"]
    }
  }
}

output "alb_controller_role_arn" {
  value = module.alb_controller.arn
}

output "external_secrets_role_arn" {
  value = module.external_secrets.arn
}

output "app_role_arn" {
  value = module.app.arn
}
