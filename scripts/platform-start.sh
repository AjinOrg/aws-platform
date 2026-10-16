#!/usr/bin/env bash
# Starts (rebuilds) the Dev environment from code (POC):
#   Terraform (VPC, EKS, IAM, Karpenter AWS side) -> ArgoCD -> root app -> everything else from Git.
# ECR images and secret values survive a normal stop, so the services come back with the same image tags and
# secrets. At the end the script checks exactly that and lists anything still missing.
#
# Usage:  bash scripts/platform-start.sh       (about 25-30 minutes)
set -euo pipefail

CLUSTER=platform-dev
REGION=${AWS_REGION:-ap-south-1}
ACCOUNT=471112815218
ARGOCD_CHART=oci://ghcr.io/argoproj/argo-helm/argo-cd
ARGOCD_VERSION=10.10.1
APP_NAMESPACES="dev staging production"
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

# Left over from the last stop if EKS wrote a final log line after the destroy: the apply would fail on it
if aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/eks/$CLUSTER/cluster" \
     --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "/aws/eks/$CLUSTER/cluster" \
   && ! aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  aws logs delete-log-group --region "$REGION" --log-group-name "/aws/eks/$CLUSTER/cluster"
  echo "   removed leftover log group /aws/eks/$CLUSTER/cluster"
fi

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

# Grafana admin login: random password in a Secret created here, never in Git (gitops/platform/monitoring.yaml)
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 24)" >/dev/null
  echo "   Grafana admin secret created"
fi

say "4/4 Waiting for all applications to be Synced and Healthy (up to 20 minutes)"
restarted=false
for i in $(seq 1 120); do
  status=$(kubectl get applications -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  total=$(echo "$status" | grep -c '=' || true)
  ready=$(echo "$status" | grep -c '=Synced/Healthy' || true)
  echo "   $ready/$total applications ready"
  if [ "$total" -ge 2 ] && [ "$ready" -eq "$total" ]; then break; fi

  # Seen after earlier starts: while add-ons come up, an aggregated API (metrics-server) is briefly unavailable,
  # ArgoCD fails to load the cluster's API schema once and then keeps that failed cache: apps stay Unknown.
  # A controller restart makes it load the schema again. Done once, after 5 minutes.
  if ! $restarted && [ "$i" -ge 30 ] && \
     kubectl get applications -n argocd -o jsonpath='{.items[*].status.conditions[*].message}' 2>/dev/null \
       | grep -qiE 'unable to handle the request|failed to load open ?api schema'; then
    echo "   ArgoCD cannot load the cluster's API schema: restarting its controller once"
    kubectl get apiservices | grep -v True || true
    kubectl rollout restart statefulset argocd-application-controller -n argocd
    restarted=true
  fi
  sleep 10
done
kubectl get applications -n argocd

say "Checking that every service finds its image and its secret"
missing=0
for ns in $APP_NAMESPACES; do
  # The image every Deployment wants, as ArgoCD rendered it from helm-chart
  for img in $(kubectl get deploy -n "$ns" -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null | sort -u); do
    repo=${img#*/}; repo=${repo%%:*}; tag=${img##*:}
    if aws ecr describe-images --region "$REGION" --repository-name "$repo" --image-ids imageTag="$tag" >/dev/null 2>&1; then
      echo "   ok       $ns  $repo:$tag"
    else
      echo "   MISSING  $ns  $repo:$tag  (not in ECR)"; missing=$((missing + 1))
    fi
  done
  # ExternalSecrets: Ready=False usually means the Secrets Manager entry has no value
  kubectl get externalsecrets -n "$ns" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | while read -r name ready; do
        [ -z "$name" ] && continue
        if [ "$ready" = "True" ]; then echo "   ok       $ns  secret $name";
        else echo "   MISSING  $ns  secret $name: store a value in platform-dev/$name/$ns (see below)"; fi
      done
done

cat <<EOF

== Started. Still to do by hand:
  1. ArgoCD password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
                      then change it (argocd account update-password) and delete that secret
  2. Grafana:         kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80  ->  http://localhost:3000
                      password: kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
Only if a line above says MISSING (normal after "platform-stop.sh --all", which deletes images and secret values):
  - Image:  dev: re-run the last main run of the service (Actions -> run -> Re-run all jobs);
            staging/production: release a tag that exists in ECR (helm-chart: scripts/release.sh)
  - Secret: aws secretsmanager put-secret-value --secret-id platform-dev/<service>/<env> --secret-string '{...}'
            (my-app: GREETING; orders: DATABASE_URL), then
            kubectl annotate externalsecret <service> -n <env> force-sync=\$(date +%s) --overwrite
EOF
[ "$missing" -eq 0 ] || echo "   $missing image(s) missing: those pods stay in ImagePullBackOff until fixed."
