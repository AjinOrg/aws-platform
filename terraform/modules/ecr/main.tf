# Private container registry for the application images.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name" {
  description = "Repository name; must match AppEcrRepository in the bootstrap (ECR push role)"
  type        = string
}

variable "keep_images" {
  description = "How many tagged images to keep"
  type        = number
  default     = 30
}

resource "aws_ecr_repository" "this" {
  name = var.name

  # A tag (the commit SHA) can never be overwritten: what was scanned and approved is what runs
  image_tag_mutability = "IMMUTABLE"

  # Basic vulnerability scan by AWS on every push (Trivy in the pipeline is the main gate)
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS" # AWS-managed key aws/ecr
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest ${var.keep_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_images
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "repository_url" {
  description = "Push/pull address, e.g. <account>.dkr.ecr.<region>.amazonaws.com/my-app"
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.this.arn
}
