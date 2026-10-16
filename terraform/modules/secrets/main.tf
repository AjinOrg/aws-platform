# Secrets Manager secrets for the services, one per service and namespace (<name>/<service>/<namespace>),
# encrypted with a dedicated KMS key. Terraform creates only the empty secret; an administrator stores the value
# with the AWS CLI, so the value never appears in Git or in the Terraform state.

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

variable "services" {
  description = "Services that read secrets (helm-chart secrets.enabled); each gets one secret per namespace"
  type        = list(string)
  default     = ["my-app"]
}

variable "namespaces" {
  description = "One secret per service and namespace: <name>/<service>/<namespace>"
  type        = list(string)
}

variable "recovery_window_days" {
  description = "Days a deleted secret can be restored (0 = delete immediately, handy for Dev rebuilds)"
  type        = number
  default     = 7
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_kms_key" "secrets" {
  description         = "${var.name}: encrypts application secrets in Secrets Manager"
  enable_key_rotation = true

  # Explicit key policy: the account's IAM policies decide who may use the key (e.g. the External Secrets
  # role may decrypt). Same as the AWS default, but written down and reviewable.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministration"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# Key "<service>/<namespace>", e.g. "orders/dev"
resource "aws_secretsmanager_secret" "app" {
  for_each = {
    for pair in setproduct(var.services, var.namespaces) : "${pair[0]}/${pair[1]}" => { service = pair[0], namespace = pair[1] }
  }

  name                    = "${var.name}/${each.key}"
  description             = "${each.value.service} settings for the ${each.value.namespace} namespace (synced by External Secrets Operator)"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.recovery_window_days
}

# The my-app secrets were keyed by namespace only (one service). Same secrets, new keys: nothing is recreated,
# so the stored values stay.
moved {
  from = aws_secretsmanager_secret.app["dev"]
  to   = aws_secretsmanager_secret.app["my-app/dev"]
}

moved {
  from = aws_secretsmanager_secret.app["staging"]
  to   = aws_secretsmanager_secret.app["my-app/staging"]
}

moved {
  from = aws_secretsmanager_secret.app["production"]
  to   = aws_secretsmanager_secret.app["my-app/production"]
}

output "secret_arns" {
  description = "Map of <service>/<namespace> => secret ARN"
  value       = { for ns, s in aws_secretsmanager_secret.app : ns => s.arn }
}

output "secret_names" {
  value = { for ns, s in aws_secretsmanager_secret.app : ns => s.name }
}

output "kms_key_arn" {
  value = aws_kms_key.secrets.arn
}
