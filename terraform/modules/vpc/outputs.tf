output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Where EKS nodes and pods run"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Where the ALB and NAT Gateway(s) live"
  value       = module.vpc.public_subnets
}

output "azs" {
  value = local.azs
}

output "nat_public_ips" {
  description = "Outbound IP(s) of the cluster, useful for allow-lists"
  value       = module.vpc.nat_public_ips
}
