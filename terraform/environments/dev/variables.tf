variable "region" {
  type = string
}

variable "environment" {
  type = string
}

# ---- network
variable "vpc_cidr" {
  type = string
}

variable "single_nat_gateway" {
  type = bool
}

variable "log_retention_days" {
  type = number
}

variable "enable_interface_endpoints" {
  type = bool
}

variable "ecr_force_delete" {
  description = "Allow terraform destroy to delete the ECR repository even if it still holds images"
  type        = bool
}

# ---- cluster
variable "kubernetes_version" {
  type = string
}

variable "admin_cidrs" {
  description = "IP ranges allowed to reach the EKS public API endpoint"
  type        = list(string)
}

variable "kms_key_administrators" {
  description = "IAM principals that administer the EKS secrets KMS key"
  type        = list(string)
}

variable "cluster_admin_arns" {
  description = "IAM principals with cluster-admin access"
  type        = list(string)
}

variable "system_instance_types" {
  type = list(string)
}

variable "system_min_size" {
  type = number
}

variable "system_max_size" {
  type = number
}

variable "system_desired_size" {
  type = number
}

# ---- application
variable "app_namespaces" {
  description = "Namespaces the app runs in on this cluster"
  type        = list(string)
}

variable "secret_recovery_window_days" {
  type = number
}
