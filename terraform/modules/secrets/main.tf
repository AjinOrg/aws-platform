# Secrets Manager secrets for the application, one per namespace, encrypted with a dedicated KMS key.
# Terraform creates only the empty secret; an administrator stores the value with the AWS CLI,
# so the value never appears in Git or in the Terraform state.

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

variable "app_name" {
  type    = string
  default = "my-app"
}

variable "namespaces" {
  description = "One secret per namespace: <name>/<app>/<namespace>"
  type        = list(string)
}

variable "recovery_window_days" {
  description = "Days a deleted secret can be restored (0 = delete immediately, handy for Dev rebuilds)"
  type        = number
  default     = 7
}

resource "aws_kms_key" "secrets" {
  description         = "${var.name}: encrypts application secrets in Secrets Manager"
  enable_key_rotation = true
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "app" {
  for_each = toset(var.namespaces)

  name                    = "${var.name}/${var.app_name}/${each.value}"
  description             = "${var.app_name} settings for the ${each.value} namespace (synced by External Secrets Operator)"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.recovery_window_days
}

output "secret_arns" {
  description = "Map of namespace => secret ARN"
  value       = { for ns, s in aws_secretsmanager_secret.app : ns => s.arn }
}

output "secret_names" {
  value = { for ns, s in aws_secretsmanager_secret.app : ns => s.name }
}

output "kms_key_arn" {
  value = aws_kms_key.secrets.arn
}
