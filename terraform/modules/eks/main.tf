# EKS cluster: AWS-managed control plane, a small "system" managed node group for platform
# add-ons, KMS encryption of Kubernetes Secrets, control plane logs, and access entries.
# Application nodes are added by Karpenter on Day 4.
# Wraps the community module terraform-aws-modules/eks.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # API endpoint: nodes and pods use the private endpoint inside the VPC;
  # the public endpoint answers only the admin IP ranges (for kubectl/helm from your computer)
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_access_cidrs

  # Kubernetes Secrets are encrypted at rest with a KMS key the module creates
  encryption_config = {
    resources = ["secrets"]
  }

  # API server, audit and authenticator logs go to CloudWatch
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # IRSA: creates the cluster's own OIDC provider so pods can assume IAM roles
  enable_irsa = true

  # Who may use kubectl: EKS access entries only (no aws-auth ConfigMap)
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  access_entries = {
    for i, arn in var.admin_principal_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    # Networking add-on; installed before the nodes so they start with the right settings
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true" # makes Kubernetes NetworkPolicies actually enforced (default-deny, Day 4)
        env = {
          ENABLE_PREFIX_DELEGATION = "true" # each node gets /28 prefixes: up to 110 pods instead of 17 on a t3.medium
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types
      capacity_type  = "ON_DEMAND" # platform add-ons must not disappear with a Spot interruption

      min_size     = var.system_min_size
      max_size     = var.system_max_size
      desired_size = var.system_desired_size

      labels = {
        "node-role" = "system"
      }

      # Matches the prefix delegation above (the AMI would otherwise assume 17 pods)
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: 110
        EOT
      }]

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # Shell access to nodes through SSM Session Manager (no SSH keys, no open port 22)
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  # Karpenter (Day 4) finds the security group for its nodes by this tag
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.name
  }
}
