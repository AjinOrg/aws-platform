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
  # Explicit key administrators. The module's default is "whoever runs Terraform", which would flip the key
  # policy between your user, the pipeline's plan role and its apply role on every run.
  kms_key_administrators = var.kms_key_administrators

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
    # EKS Pod Identity: how Karpenter's controller gets its AWS credentials (see module "karpenter" below)
    eks-pod-identity-agent = {
      before_compute = true
    }
    # CPU/memory usage of pods: needed by the HorizontalPodAutoscaler and `kubectl top`
    # Pinned on purpose (without a version the module installs the newest one at every apply):
    # v0.9.0-eksbuild.12 published an OpenAPI schema the API server could not serve as protobuf, and ArgoCD lost
    # sight of the cluster (all apps Unknown, 2026-10-16). Upgrade only after the protobuf test (docs/runbook.md).
    metrics-server = {
      addon_version = "v0.9.0-eksbuild.13"
    }
    # Creates EBS volumes for PersistentVolumeClaims (monitoring data). AWS access through EKS Pod Identity.
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
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

# AWS side of Karpenter (the controller itself is installed by ArgoCD):
# - controller IAM role, linked to the service account kube-system/karpenter with EKS Pod Identity
#   (this module version supports Pod Identity only; it is AWS's newer alternative to IRSA)
# - node IAM role + instance profile + EKS access entry, so nodes Karpenter launches can join the cluster
# - SQS queue + EventBridge rules: AWS warns ~2 minutes before reclaiming a Spot instance, and Karpenter
#   moves the pods off that node in time
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  namespace       = "kube-system"
  service_account = "karpenter"

  iam_role_name            = "${var.name}-karpenter"
  iam_role_use_name_prefix = false

  node_iam_role_name            = "${var.name}-karpenter-node"
  node_iam_role_use_name_prefix = false
  node_iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # Session Manager access, no SSH
  }

  queue_name = "${var.name}-karpenter"
}
# IAM role for the EBS CSI driver's controller (kube-system/ebs-csi-controller-sa), via EKS Pod Identity:
# create/attach/delete EBS volumes for PersistentVolumeClaims. AWS-managed policy, scoped by AWS to EBS actions.
resource "aws_iam_role" "ebs_csi" {
  name        = "${var.name}-ebs-csi"
  description = "EBS CSI driver controller (EKS Pod Identity)"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
