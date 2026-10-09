# VPC with public and private subnets in each AZ, NAT for outbound traffic,
# VPC endpoints so AWS API traffic stays on the AWS network, and flow logs.
# Wraps the community module terraform-aws-modules/vpc, which is widely used and maintained.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # 10.0.0.0/16 -> private /19s (8,190 IPs each, room for pod IPs) and public /24s (ALB + NAT only)
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.cidr, 3, i)]      # 10.0.0.0/19, 10.0.32.0/19, 10.0.64.0/19
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, 96 + i)] # 10.0.96.0/24, 10.0.97.0/24, 10.0.98.0/24
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nothing launched in a public subnet gets a public IP unless asked for explicitly
  map_public_ip_on_launch = false

  # Lock down the default security group (no rules = no traffic)
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Record accepted/rejected traffic for troubleshooting and audits
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days

  # The AWS Load Balancer Controller puts internet-facing ALBs in subnets tagged "elb"
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  # Internal load balancers go to "internal-elb" subnets; Karpenter launches nodes in subnets with its discovery tag
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }
}

# Interface endpoints listen on HTTPS inside the VPC; only the VPC itself may reach them
module "endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"

  vpc_id = module.vpc.vpc_id

  create_security_group      = true
  security_group_name_prefix = "${var.name}-vpce-"
  security_group_description = "HTTPS from inside the VPC to the VPC endpoints"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from the VPC"
      cidr_blocks = [var.cidr]
    }
  }

  endpoints = {
    # Gateway endpoint: free, used for ECR image layers (stored in S3) and Terraform/app S3 access
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${var.name}-s3" }
    }
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags                = { Name = "${var.name}-ecr-api" }
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags                = { Name = "${var.name}-ecr-dkr" }
    }
    sts = { # IRSA: pods exchange their token for AWS credentials here
      service             = "sts"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags                = { Name = "${var.name}-sts" }
    }
    secretsmanager = { # External Secrets Operator reads secrets here
      service             = "secretsmanager"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags                = { Name = "${var.name}-secretsmanager" }
    }
  }
}
