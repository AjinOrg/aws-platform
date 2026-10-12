output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "The cluster's OIDC provider; IRSA role trust policies point to it"
  value       = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "karpenter_controller_role_arn" {
  value = module.karpenter.iam_role_arn
}

output "karpenter_node_role_name" {
  description = "Goes into the Karpenter EC2NodeClass (spec.role)"
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  description = "Goes into the Karpenter Helm values (settings.interruptionQueue)"
  value       = module.karpenter.queue_name
}

output "system_node_iam_role_arn" {
  value = module.eks.eks_managed_node_groups["system"].iam_role_arn
}
