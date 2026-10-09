variable "name" {
  description = "Name prefix for the VPC and its resources, e.g. platform-dev"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block (a /16; must not overlap with other environments)"
  type        = string
}

variable "az_count" {
  description = "Number of Availability Zones to spread the subnets over"
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "true = one shared NAT Gateway (Dev, cheaper); false = one per AZ (Staging/Production, no single point of failure)"
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "EKS cluster name; used for the subnet tags the load balancer controller and Karpenter look for"
  type        = string
}

variable "flow_log_retention_days" {
  description = "How long VPC flow logs are kept in CloudWatch"
  type        = number
  default     = 7
}
