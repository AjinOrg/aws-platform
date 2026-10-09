output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "app_secret_names" {
  value = module.secrets.secret_names
}

output "irsa_role_arns" {
  value = {
    alb_controller   = module.iam.alb_controller_role_arn
    external_secrets = module.iam.external_secrets_role_arn
    app              = module.iam.app_role_arn
  }
}
