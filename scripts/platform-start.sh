#!/usr/bin/env bash
# Starts (rebuilds) the Dev environment from code (POC):
#   Terraform (VPC, EKS, ECR, secrets, IAM, Karpenter AWS side) -> ArgoCD -> root app -> everything else from Git.
#
# Usage:  bash scripts/platform-start.sh       (about 25-30 minutes)
set -euo pipefail

CLUSTER=platform-dev
REGION=${AWS_REGION:-ap-south-1}
ACCOUNT=471112815218
ARGOCD_CHART=oci://ghcr.io/argoproj/argo-helm/argo-cd
ARGOCD_VERSION=10.10.1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/dev"

say() { printf '\n== %s\n' "$*"; }

say "Checking AWS account"
actual=$(aws sts get-caller-identity --query Account --output text)
[ "$actual" = "$ACCOUNT" ] || { echo "Wrong AWS account: $actual (expected $ACCOUNT). Check AWS_PROFILE."; exit 1; }

say "Checking your public IP is allowed to reach the cluster API"
myip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
if ! grep -q "\"$myip/32\"" "$TF_DIR/terraform.tfvars"; then
  echo "Your IP $myip is not in admin_cidrs in terraform/environments/dev/terraform.tfvars."
  echo "Update it (\"$myip/32\"), then run this script again."; exit 1
fi
echo "   $myip/32 is allowed"

say "1/4 Terraform: plan"
cd "$TF_DIR"
terraform init -input=false >/dev/null
terraform plan -out=tfplan -input=false
read -r -p "Apply this plan? Type 'yes': " ans
[ "$ans" = "yes" ] || { rm -f tfplan; echo "Cancelled. Nothing was created."; exit 1; }
terraform apply -input=false tfplan
rm -f tfplan

say "2/4 Connect kubectl and wait for the nodes"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=10m

say "3/4 Install ArgoCD and hand over to Git"
helm upgrade --install argocd "$ARGOCD_CHART" -n argocd --create-namespace \
  --version "$ARGOCD_VERSION" -f "$ROOT/gitops/bootstrap/argocd-values.yaml" --wait --timeout 10m
kubectl apply -f "$ROOT/gitops/bootstrap/root-app.yaml"

say "4/4 Waiting for all applications to be Synced and Healthy (up to 15 minutes)"
for i in $(seq 1 90); do
  status=$(kubectl get applications -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  total=$(echo "$status" | grep -c '=' || true)
  ready=$(echo "$status" | grep -c '=Synced/Healthy' || true)
  echo "   $ready/$total applications ready"
  if [ "$total" -ge 2 ] && [ "$ready" -eq "$total" ]; then break; fi
  sleep 10
done
kubectl get applications -n argocd

cat <<EOF

== Started. Still to do by hand (values are never stored in Git):
  1. Secret values:   for ns in dev staging production; do
                        aws secretsmanager put-secret-value --secret-id platform-dev/my-app/\$ns --secret-string '{...}'
                      done
  2. ArgoCD password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
                      then change it (argocd account update-password) and delete that secret
  3. App image:       ECR is empty after a rebuild: re-run the my-app release pipeline (Day 6) or push the image
EOF
