# Dev: everything that differs between environments lives in this file.
region      = "ap-south-1"
environment = "dev"

# ---- network
vpc_cidr           = "10.0.0.0/16"
single_nat_gateway = true # one shared NAT to save cost; staging/production use one per AZ
log_retention_days = 7

# ---- cluster
kubernetes_version = "1.36"      # newest "STANDARD_SUPPORT" version from: aws eks describe-cluster-versions
admin_cidrs        = ["103.141.54.90/32"] # your public IP: curl -s https://checkip.amazonaws.com
cluster_admin_arns = [
  "arn:aws:iam::471112815218:user/ajin.vijayan@urolime.com",
]
system_instance_types = ["t3.medium"]
system_min_size       = 2
system_max_size       = 3
system_desired_size   = 2

# ---- application
# Initial delivery: one cluster runs all three namespaces; dedicated clusters come later
app_namespaces              = ["dev", "staging", "production"]
secret_recovery_window_days = 0 # Dev only: lets a destroyed environment be rebuilt at once
