# Remote state in the bucket created by bootstrap/state-backend.yaml.
# Backend blocks cannot use variables, so the values are written here directly.
terraform {
  backend "s3" {
    bucket       = "aws-platform-tfstate-471112815218"
    key          = "aws-platform/dev/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true # S3 native locking: a .tflock object, no DynamoDB table
  }
}
