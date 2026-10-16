# Dev: everything that differs between environments lives in this file.
region      = "ap-south-1"
environment = "dev"

# ---- network
vpc_cidr           = "10.0.0.0/16"
single_nat_gateway = true # one shared NAT to save cost; staging/production use one per AZ
log_retention_days = 7
# POC cost saving (~$3/day): no paid interface endpoints; ECR/STS/Secrets Manager traffic goes through the NAT
# Gateway instead (still TLS-encrypted). Set to true for the design's private-endpoint setup.
enable_interface_endpoints = false

# ---- cluster
kubernetes_version = "1.36"               # newest "STANDARD_SUPPORT" version from: aws eks describe-cluster-versions
admin_cidrs        = ["103.141.54.90/32"] # your public IP: curl -s https://checkip.amazonaws.com
cluster_admin_arns = [
  "arn:aws:iam::471112815218:user/ajin.vijayan@urolime.com",
  "arn:aws:iam::471112815218:root",
]
# Administrators of the EKS secrets KMS key: the pipeline's apply role + the local admin user.
# Fixed list, so the key policy does not change with whoever runs Terraform.
kms_key_administrators = [
  "arn:aws:iam::471112815218:role/aws-platform-terraform-apply",
  "arn:aws:iam::471112815218:user/ajin.vijayan@urolime.com",
]
system_instance_types = ["t3.medium"]
system_min_size       = 2
system_max_size       = 3
system_desired_size   = 2

# ---- application
# Initial delivery: one cluster runs all three namespaces; dedicated clusters come later.
# services_with_secrets: one Secrets Manager secret per service and namespace (plus secrets.enabled in helm-chart)
app_namespaces              = ["dev", "staging", "production"]
services_with_secrets       = ["my-app", "orders"]
secret_recovery_window_days = 0    # Dev only: lets a destroyed environment be rebuilt at once
ecr_force_delete            = true # Dev/POC only: scripts/platform-stop.sh can destroy the registry with its images
