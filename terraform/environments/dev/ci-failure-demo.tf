# DEMO (branch demo/ci-failures, never merged). Expected:
#   - Terraform fmt fails (indentation and alignment are wrong on purpose)
#   - Checkov fails: SSH (22) open to the whole internet, unrestricted egress
resource "aws_security_group" "ci_failure_demo" {
name = "ci-failure-demo"
    description="DEMO - must be rejected by Checkov"

  ingress {
    description = "SSH from anywhere"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Everything to anywhere"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
