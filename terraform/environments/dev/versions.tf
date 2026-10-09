terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Credentials come from the environment: AWS_PROFILE locally, GitHub OIDC in the pipeline.
provider "aws" {
  region = var.region

  # Every resource gets these tags automatically (cost reports, ownership)
  default_tags {
    tags = {
      Project     = "aws-platform"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
