variable "name" {
  description = "Cluster name, e.g. platform-dev"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version, e.g. 1.35 (kubectl must be within one minor version)"
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "Set kubernetes_version to a version like \"1.35\" (see aws eks describe-cluster-versions)."
  }
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Nodes and the control plane's network interfaces go here"
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "IP ranges allowed to reach the public API endpoint (your office/home IP as x.x.x.x/32)"
  type        = list(string)

  validation {
    condition = length(var.public_access_cidrs) > 0 && !contains(var.public_access_cidrs, "0.0.0.0/0") && alltrue([
      for c in var.public_access_cidrs : can(cidrnetmask(c))
    ])
    error_message = "Give at least one valid admin IP range like 203.0.113.25/32; 0.0.0.0/0 (the whole internet) is not allowed."
  }
}

variable "admin_principal_arns" {
  description = "IAM users/roles that get cluster-admin through EKS access entries"
  type        = list(string)
}

variable "system_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "system_min_size" {
  type    = number
  default = 2
}

variable "system_max_size" {
  type    = number
  default = 3
}

variable "system_desired_size" {
  type    = number
  default = 2
}

variable "log_retention_days" {
  description = "CloudWatch retention for the control plane logs"
  type        = number
  default     = 7
}
