#!/usr/bin/env bash
# Stops the Dev environment to save cost (POC): removes what the cluster itself created in AWS
# (load balancers and their security groups, Karpenter nodes and instance profiles, EBS volumes), uninstalls
# ArgoCD, then destroys the Terraform-managed Dev infrastructure.
#
# Default: the ECR repositories (with their images) and the Secrets Manager secrets (with their values) are KEPT,
# so after a start staging and production find their image tags again and no secret has to be stored again.
# They cost about $3-4 per month together. --all destroys them too (end of the POC).
#
# Kept always: the bootstrap stack (state bucket, KMS key, GitHub OIDC, pipeline roles) and everything in Git.
#
# Usage:  bash scripts/platform-stop.sh          (about 15-20 minutes)
#         bash scripts/platform-stop.sh --all    (also deletes the images and the secret values)
set -euo pipefail

CLUSTER=platform-dev
REGION=${AWS_REGION:-ap-south-1}
ACCOUNT=471112815218
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/dev"

# What a normal stop destroys: everything that costs money by the hour. Not listed = kept:
# module.ecr, module.ecr_orders (images), module.secrets (secret values and their KMS key).
STOP_TARGETS=(module.iam module.eks module.vpc)

ALL=false
case "${1:-}" in
  "") ;;
  --all) ALL=true ;;
  *) echo "Usage: $0 [--all]"; exit 1 ;;
esac

say() { printf '\n== %s\n' "$*"; }

say "Checking AWS account"
actual=$(aws sts get-caller-identity --query Account --output text)
[ "$actual" = "$ACCOUNT" ] || { echo "Wrong AWS account: $actual (expected $ACCOUNT). Check AWS_PROFILE."; exit 1; }

if $ALL; then
  destroys="VPC, NAT Gateway, EKS cluster $CLUSTER and its nodes, load balancers, IRSA roles,
  ECR repositories (WITH their images) and Secrets Manager secrets (WITH their values)."
  kept="bootstrap stack, Terraform state bucket, and everything in Git."
else
  destroys="VPC, NAT Gateway, EKS cluster $CLUSTER and its nodes, load balancers, IRSA roles."
  kept="ECR repositories with their images, Secrets Manager secrets with their values,
  bootstrap stack, Terraform state bucket, and everything in Git."
fi
cat <<EOF

This DESTROYS the Dev environment in $REGION:
  $destroys
Kept: $kept
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
  # Without access to the API the Kubernetes clean-up below is skipped silently, and the load balancers it
  # should remove then block the VPC deletion. Check first (the IP of a laptop changes between networks).
  say "Checking your public IP may reach the cluster API"
  myip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
  allowed=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
              --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text)
  if ! echo "$allowed" | tr '\t' '\n' | grep -qx "$myip/32"; then
    echo "Your IP $myip is not allowed (cluster allows: $allowed)."
    echo "Add \"$myip/32\" to admin_cidrs in terraform/environments/dev/terraform.tfvars, terraform apply, run again."
    exit 1
  fi
  echo "   $myip/32 is allowed"

  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
  kubectl get --raw /readyz >/dev/null || { echo "kubectl cannot reach the cluster. Fix that first."; exit 1; }

  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    say "1/5 Stop ArgoCD from re-creating things: delete the root app (its children stay for now)"
    kubectl delete application root -n argocd --ignore-not-found --wait=true
    # ApplicationSets would re-create the Applications they generate. "microservices" keeps its services'
    # resources on deletion (preserveResourcesOnDeletion): the Ingress clean-up below removes their ALB rules.
    kubectl delete applicationsets --all -n argocd --wait=false || true

    say "2/5 Delete applications: Ingresses -> ALBs removed, NodePools -> Karpenter nodes removed"
    # The two controllers that clean up AWS resources are kept until their resources are gone
    for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
      case "$app" in aws-load-balancer-controller|karpenter) continue ;; esac
      kubectl delete application "$app" -n argocd --wait=false
    done
  fi

  # Safety net for objects not owned by ArgoCD (or kept by preserveResourcesOnDeletion)
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

  # Karpenter creates an instance profile per EC2NodeClass (not Terraform). It removes it when the EC2NodeClass
  # is deleted, but only while it still runs; a profile left behind holds the node role, and Terraform then
  # cannot delete that role (DeleteConflict).
  if kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; then
    echo "   deleting EC2NodeClasses (Karpenter removes their instance profiles)"
    kubectl delete ec2nodeclasses.karpenter.k8s.aws --all --wait=true --timeout=3m || true
  fi

  # Volumes for PersistentVolumeClaims are created by the EBS CSI driver, not by Terraform. Delete the claims
  # while the driver still runs, so it deletes the EBS volumes (StorageClass reclaimPolicy: Delete).
  if [ -n "$(kubectl get pvc -A --no-headers 2>/dev/null)" ]; then
    echo "   deleting PersistentVolumeClaims (their EBS volumes are deleted with them)"
    kubectl delete pvc --all -A --wait=true --timeout=5m || true
    for i in $(seq 1 30); do
      [ -z "$(kubectl get pv --no-headers 2>/dev/null)" ] && break
      sleep 10
    done
  fi

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
# EBS volumes left by the CSI driver (should be none after the PVC clean-up) still cost money
vols=$(aws ec2 describe-volumes --region "$REGION" \
         --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" "Name=status,Values=available" \
         --query 'Volumes[].VolumeId' --output text)
for v in $vols; do echo "Deleting leftover EBS volume $v"; aws ec2 delete-volume --region "$REGION" --volume-id "$v"; done

lbs=$(cluster_load_balancers)
if [ -n "$lbs" ]; then
  echo "Load balancers still exist: $lbs"
  echo "Delete them (EC2 console > Load Balancers) and run this script again."; exit 1
fi

# Security groups the load balancer controller created for the ALB (k8s-*). Normally removed with the ALB;
# one left behind blocks the VPC deletion ("DependencyViolation"). Retried: the ALB's network interfaces
# may need a minute to go.
for sg in $(aws ec2 describe-security-groups --region "$REGION" \
              --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'SecurityGroups[].GroupId' --output text); do
  for i in 1 2 3 4 5 6; do
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null \
      && { echo "Deleted leftover load balancer security group $sg"; break; }
    sleep 10
  done
done

say "5/5 terraform destroy (review the plan)"
cd "$TF_DIR"
terraform init -input=false >/dev/null
if $ALL; then
  terraform plan -destroy -out=destroy.tfplan -input=false
else
  # -target: only these modules and what depends on them. Terraform warns that targeting is in effect;
  # that is expected here. The plan must NOT list module.ecr, module.ecr_orders or module.secrets.
  terraform plan -destroy -out=destroy.tfplan -input=false "${STOP_TARGETS[@]/#/-target=}"
  if terraform show -no-color destroy.tfplan | grep -qE '# module\.(ecr|ecr_orders|secrets)\.'; then
    rm -f destroy.tfplan
    echo "The plan would delete ECR or Secrets Manager resources, which a normal stop keeps. Stopped; nothing destroyed."
    exit 1
  fi
fi
read -r -p "Apply this destroy plan? Type 'yes': " ans
[ "$ans" = "yes" ] || { rm -f destroy.tfplan; echo "Cancelled. Nothing was destroyed by Terraform."; exit 1; }
terraform apply -input=false destroy.tfplan
rm -f destroy.tfplan

# EKS can write one last log line after Terraform deleted its log group, re-creating it.
# A re-created group would make the next start fail with "already exists".
sleep 30
aws logs delete-log-group --region "$REGION" --log-group-name "/aws/eks/$CLUSTER/cluster" 2>/dev/null \
  && echo "Removed re-created log group /aws/eks/$CLUSTER/cluster" || true

if $ALL; then
  say "Stopped. Remaining cost: state bucket + bootstrap KMS key (a few cents per day)."
  echo "After the next start: store the secret values and rebuild the images (see the start script's output)."
else
  say "Stopped. Remaining cost: ECR images, secrets and their KMS key, state bucket (about \$3-4 per month)."
fi
echo "Start again with: bash scripts/platform-start.sh"
