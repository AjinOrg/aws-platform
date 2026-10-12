#!/usr/bin/env bash
# Stops the Dev environment to save cost (POC): removes what the cluster itself created in AWS
# (load balancers, Karpenter nodes), uninstalls ArgoCD, then destroys the Terraform-managed Dev infrastructure.
#
# Kept: the bootstrap stack (state bucket, KMS key, GitHub OIDC, pipeline roles) and everything in Git.
# Lost: secret VALUES in Secrets Manager and images in ECR (store/push them again after a start).
#
# Usage:  bash scripts/platform-stop.sh        (about 15-20 minutes)
set -euo pipefail

CLUSTER=platform-dev
REGION=${AWS_REGION:-ap-south-1}
ACCOUNT=471112815218
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/dev"

say() { printf '\n== %s\n' "$*"; }

say "Checking AWS account"
actual=$(aws sts get-caller-identity --query Account --output text)
[ "$actual" = "$ACCOUNT" ] || { echo "Wrong AWS account: $actual (expected $ACCOUNT). Check AWS_PROFILE."; exit 1; }

cat <<EOF

This DESTROYS the Dev environment in $REGION:
  VPC, NAT Gateway, EKS cluster $CLUSTER and its nodes, load balancers,
  ECR repository (with its images), Secrets Manager secrets (with their values), IRSA roles.
Kept: bootstrap stack, Terraform state bucket, and everything in Git.
EOF
read -r -p "Type 'stop' to continue: " ans
[ "$ans" = "stop" ] || { echo "Cancelled."; exit 1; }

# Instances launched by Karpenter (not by Terraform)
karpenter_instances() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
              "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# Load balancers created by the AWS Load Balancer Controller for this cluster
cluster_load_balancers() {
  aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
}

if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    say "1/5 Stop ArgoCD from re-creating things: delete the root app (its children stay for now)"
    kubectl delete application root -n argocd --ignore-not-found --wait=true

    say "2/5 Delete applications: Ingresses -> ALBs removed, NodePools -> Karpenter nodes removed"
    # The two controllers that clean up AWS resources are kept until their resources are gone
    for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
      case "$app" in aws-load-balancer-controller|karpenter) continue ;; esac
      kubectl delete application "$app" -n argocd --wait=false
    done
  fi

  # Safety net for objects not owned by ArgoCD
  kubectl delete ingress --all -A --ignore-not-found --wait=false || true
  if kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    kubectl delete nodepools.karpenter.sh --all --wait=false || true
  fi

  say "3/5 Waiting for load balancers and Karpenter nodes to disappear (up to 10 minutes)"
  for i in $(seq 1 60); do
    lbs=$(cluster_load_balancers); nodes=$(karpenter_instances)
    if [ -z "$lbs" ] && [ -z "$nodes" ]; then echo "   all gone"; break; fi
    echo "   still there: load balancers=$(echo $lbs | wc -w) karpenter nodes=$(echo $nodes | wc -w)"
    sleep 10
  done

  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    say "4/5 Remove the remaining applications and ArgoCD"
    kubectl delete applications --all -n argocd --wait=true --timeout=5m || true
    helm uninstall argocd -n argocd --wait || true
  fi
else
  echo "Cluster $CLUSTER not found: skipping the Kubernetes clean-up."
fi

# Anything still left would block the VPC from being deleted
leftover=$(karpenter_instances)
if [ -n "$leftover" ]; then
  echo "Terminating leftover Karpenter instances: $leftover"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $leftover >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $leftover
fi
lbs=$(cluster_load_balancers)
if [ -n "$lbs" ]; then
  echo "Load balancers still exist: $lbs"
  echo "Delete them (EC2 console > Load Balancers) and run this script again."; exit 1
fi

say "5/5 terraform destroy (review the plan)"
cd "$TF_DIR"
terraform init -input=false >/dev/null
terraform plan -destroy -out=destroy.tfplan -input=false
read -r -p "Apply this destroy plan? Type 'yes': " ans
[ "$ans" = "yes" ] || { rm -f destroy.tfplan; echo "Cancelled. Nothing was destroyed by Terraform."; exit 1; }
terraform apply -input=false destroy.tfplan
rm -f destroy.tfplan

# EKS can write one last log line after Terraform deleted its log group, re-creating it.
# A re-created group would make the next start fail with "already exists".
aws logs delete-log-group --region "$REGION" --log-group-name "/aws/eks/$CLUSTER/cluster" 2>/dev/null \
  && echo "Removed re-created log group /aws/eks/$CLUSTER/cluster" || true

say "Stopped. Remaining cost: state bucket + bootstrap KMS key (a few cents per day)."
echo "Start again with: bash scripts/platform-start.sh"
