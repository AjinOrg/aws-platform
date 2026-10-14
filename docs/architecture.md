# Architecture (as built)

The platform as it runs in the POC. Design reference: `AWS_Platform_Proposal_v1.6`. Differences from the design are
marked **(POC)** and listed in [trade-offs.md](trade-offs.md). Diagrams of the design: `aws-platform-docs/diagrams/`.

## Contents
1. [Three layers](#1-three-layers)
2. [Request flow](#2-request-flow)
3. [Network](#3-network)
4. [EKS cluster](#4-eks-cluster)
5. [Repositories and delivery flow](#5-repositories-and-delivery-flow)
6. [Infrastructure and state](#6-infrastructure-and-state)
7. [Security](#7-security)
8. [Identities: who can do what](#8-identities-who-can-do-what)
9. [Monitoring](#9-monitoring)
10. [Environments](#10-environments)
11. [Versions](#11-versions)

---

## 1. Three layers

```
┌─ Layer 3: inside the cluster ─────────────────────────────────────────────────────────────┐
│ ArgoCD · ALB controller · Karpenter · External Secrets · Kyverno · monitoring · my-app     │
│ Managed by: ArgoCD (GitOps), from gitops/ on main of AjinOrg/aws-platform                  │
└───────────────────────────────────────▲────────────────────────────────────────────────────┘
                                        │ runs on
┌─ Layer 2: AWS resources ──────────────┴────────────────────────────────────────────────────┐
│ VPC · NAT · EKS + system nodes · ECR · Secrets Manager · IAM roles · add-ons               │
│ Managed by: Terraform (terraform/), through the Terraform pipeline (plan on PR, apply after│
│ approval); state in the S3 bucket below                                                    │
└───────────────────────────────────────▲────────────────────────────────────────────────────┘
                                        │ needs first
┌─ Layer 1: foundation (once per account) ───────────────────────────────────────────────────┐
│ State bucket · KMS key · GitHub OIDC provider · pipeline roles                             │
│ Managed by: CloudFormation (bootstrap/state-backend.yaml), stack aws-platform-bootstrap    │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Layer | Tool | Changes | Why this tool |
|---|---|---|---|
| 1 Foundation | CloudFormation | Almost never | Terraform needs its state bucket before it can run |
| 2 AWS resources | Terraform (pipeline) | Rarely, reviewed plan + approval | Modules, reviewable plans, one folder per environment |
| 3 Cluster contents | ArgoCD | Often, via Git | Git is the only way in; drift is reverted; rebuild from Git |

---

## 2. Request flow

```
User (browser)
   │ HTTP :80  (POC: no domain → no TLS; HTTPS = ACM certificate + 2 Ingress annotations)
   ▼
Application Load Balancer  k8s-myapp-…elb.amazonaws.com    public subnets, 3 AZs
   │ ONE ALB shared by dev, staging, production (IngressGroup "my-app") (POC: cost)
   │ path /dev → dev · /staging → staging · /production → production · health check /readyz
   ▼  target type ip: straight to pod IPs (allowed by NetworkPolicy from 10.0.96.0/22 on 8080)
my-app pods   private subnets, Karpenter Spot nodes (node-role=apps)
   │ secrets as files: /etc/my-app/secrets/<KEY>  ← Kubernetes Secret ← External Secrets ← Secrets Manager
   └ logs → Loki · metrics (CPU, memory, restarts, replicas) → Prometheus
```

---

## 3. Network

```
VPC 10.0.0.0/16 (platform-dev), ap-south-1a / 1b / 1c
├── public  10.0.96.0/24 · 10.0.97.0/24 · 10.0.98.0/24     ALB, NAT Gateway (1, shared)
├── private 10.0.0.0/19 · 10.0.32.0/19 · 10.0.64.0/19       EKS nodes and pods (VPC CNI: pod = VPC IP)
├── S3 gateway endpoint (free)                               ECR image layers, S3
└── flow logs → CloudWatch (7 days)
```

| Component | As built |
|---|---|
| NAT | 1 shared (Dev); staging/production design: 1 per AZ |
| Interface endpoints (ECR, STS, Secrets Manager) | **Off in Dev (POC: ~$3/day)**: that traffic goes through NAT, still TLS. `enable_interface_endpoints = true` turns them on |
| Default security group | Emptied (no traffic) |
| Public IPs | None assigned automatically |
| EKS API | Private endpoint for nodes; public endpoint only from `admin_cidrs` (one /32) |
| Pod-to-pod | Default-deny NetworkPolicies in dev/staging/production; enforced by the VPC CNI network policy agent |

---

## 4. EKS cluster

```
EKS platform-dev (Kubernetes 1.36, control plane managed by AWS)
│
├── system node group: 2 × t3.medium On-Demand, label node-role=system   (Terraform)
│     kube-system: CoreDNS, ALB controller ×2, Karpenter ×2, EBS CSI controller
│     argocd: ArgoCD   ·   external-secrets   ·   kyverno (4 controllers)
│
└── Karpenter NodePool "apps": Spot, t/m/c, 2–4 vCPU, ≥ ~4 GiB, limit 16 vCPU / 64 Gi, label node-role=apps
      dev / staging / production: my-app
      monitoring: Prometheus, Alertmanager, Grafana, Loki, Alloy, kube-state-metrics (2 Gi gp3 volumes)
```

| Feature | As built |
|---|---|
| Add-ons | vpc-cni (prefix delegation → 110 pods/node; network policy agent), kube-proxy, CoreDNS, eks-pod-identity-agent, metrics-server, aws-ebs-csi-driver |
| Secrets encryption | KMS key; administrators fixed in `terraform.tfvars` (apply role + admin user), so the key policy does not change with who runs Terraform |
| Control-plane logs | api, audit, authenticator → CloudWatch (7 days) |
| Cluster access | EKS access entries only (`authentication_mode = API`); admins listed in `cluster_admin_arns` |
| Nodes | AL2023, encrypted gp3 disks, IMDSv2 with hop limit 1 (pods cannot use the node role), SSM access, no SSH |
| Storage | StorageClass `gp3` (default): encrypted, `WaitForFirstConsumer`, `reclaimPolicy: Delete`, expandable |
| Karpenter | Pod Identity; SQS interruption queue (2-minute Spot warnings); consolidation after 5 min; nodes replaced weekly |

---

## 5. Repositories and delivery flow

| Repository | Contains | Who |
|---|---|---|
| `AjinOrg/my-app` | Application code, tests, Dockerfile, its pipeline | Developers (Write) |
| `AjinOrg/aws-platform` | Bootstrap, Terraform, Helm chart, GitOps, policies, monitoring, docs, workflows | Platform team (Code Owners) |

```
my-app PR ── checks: Gitleaks · lint+tests+coverage · SonarQube (Phase 2) · npm audit/OWASP · Trivy fs
             · build · Trivy image · Kyverno  (branch must be up to date with main)
   │ merge
   ▼
my-app main ── build · Trivy image · Kyverno · OIDC → ECR push (tag = 7-char SHA)
             · GitHub App → PR "deploy(dev)" in aws-platform
   ▼
DEV        platform-ci green → PR merges ITSELF → ArgoCD (polls every 60 s) → verify.yaml smoke test
   │ a person: release.yaml (form) or scripts/release.sh (menu) — tag must have run in dev
   ▼
STAGING    release PR → platform-ci → merges itself → ArgoCD → verify.yaml
   │ a person: release → production — tag must have run in staging
   ▼
PRODUCTION release PR → platform-ci → Code Owner APPROVES → ArgoCD → verify.yaml
```

ArgoCD watches only `aws-platform`. App-of-apps: `gitops/bootstrap/root-app.yaml` → `gitops/platform/*.yaml`
(add-ons, project `platform`) and `gitops/apps/*.yaml` (ApplicationSet `my-app` → 3 Applications, project `apps`).
Details: [delivery-flow in README §10f](../README.md#10f-step-11-continuous-delivery-dev--staging--production).

---

## 6. Infrastructure and state

```
CloudFormation aws-platform-bootstrap
   ├── S3 aws-platform-tfstate-471112815218 (versioned, KMS, public access blocked, HTTPS only, retained)
   ├── KMS alias/aws-platform-tfstate (rotation on, retained)
   ├── GitHub OIDC provider token.actions.githubusercontent.com
   └── roles: aws-platform-ecr-push · aws-platform-terraform-plan (read-only) · aws-platform-terraform-apply
          trust: GitHub immutable subject  repo:AjinOrg@339973007/<repo>@<repo-id>:<context>
   ▼
Terraform pipeline (.github/workflows/terraform.yaml)
   PR: plan (read-only role) → PR comment + tfplan.txt artifact
   main: plan → saved plan → GitHub Environment terraform-apply (approval) → apply role → apply saved plan
   state: aws-platform/dev/terraform.tfstate · S3 native locking (use_lockfile)
```

---

## 7. Security

| Layer | Controls |
|---|---|
| Pull request (shift-left) | Gitleaks, Trivy (fs + image), npm audit / OWASP Dependency-Check, Checkov (Terraform, CloudFormation, chart), kubeconform, Kyverno CLI, SonarQube (Phase 2). Any failure blocks the merge (rulesets) |
| Repository | Rulesets on main: PR required, required checks, no force push/deletion; CODEOWNERS approval for production values and infrastructure; my-app: branch must be up to date |
| Admission (cluster) | Kyverno, 6 policies, Enforce, in dev/staging/production: no privileged, non-root, ECR-only images, requests + memory limit, no `:latest`, probes (a 7th, no scale-to-0, is ready on a branch). Pod Security Admission `restricted` on the same namespaces |
| Network | Private subnets; default-deny NetworkPolicies; API endpoint restricted to one /32 |
| Identity | GitHub OIDC (no keys in GitHub); IRSA / Pod Identity per workload; EKS access entries; IMDS hop limit 1 |
| Secrets | Secrets Manager + KMS; External Secrets; values never in Git or Terraform state; Grafana/ArgoCD admin secrets created outside Git |
| Images | ECR immutable tags, scan on push; distroless, non-root, read-only filesystem |
| Supply chain | CI tools pinned with checksum verification; charts pinned by version |

---

## 8. Identities: who can do what

| Identity | Mechanism | Can | Cannot |
|---|---|---|---|
| `aws-platform-ecr-push` | GitHub OIDC from `my-app` main | Push/read `my-app` images | Anything else in AWS |
| `aws-platform-terraform-plan` | GitHub OIDC from `aws-platform` PRs and main | Read the account + state (plan, find the ALB, check ECR) | Change AWS |
| `aws-platform-terraform-apply` | GitHub OIDC from environment `terraform-apply` only | Apply Terraform (admin) | Be used without a reviewer's approval |
| GitHub App `ajinorg-deployer` | 1-hour tokens | Open PRs / push branches in `aws-platform` | Push to main, approve production, touch `my-app` |
| `platform-dev-alb-controller` | IRSA `kube-system/aws-load-balancer-controller` | Manage load balancers | — |
| `platform-dev-external-secrets` | IRSA `external-secrets/external-secrets` | Read the 3 app secrets, decrypt with their key | Other secrets |
| `platform-dev-karpenter` | Pod Identity `kube-system/karpenter` | Launch/terminate nodes | — |
| `platform-dev-ebs-csi` | Pod Identity `kube-system/ebs-csi-controller-sa` | Create/attach/delete EBS volumes | — |
| `platform-dev-my-app` | IRSA `<env>/my-app` | Nothing yet (add only what the app needs) | — |
| ArgoCD | In-cluster | Apply what is on `aws-platform` main, within its AppProjects | Read other repositories |

---

## 9. Monitoring

```
node-exporter · kube-state-metrics · kubelet/cAdvisor ──▶ Prometheus (2 Gi, 2 days) ──▶ Alertmanager (2 Gi, 48 h)
pod logs ── Alloy (Kubernetes API) ─────────────────────▶ Loki (2 Gi, 48 h)
                                  Grafana (2 Gi): dashboards (built-in + "my-app") · Explore (Loki) · Alerting
Access: kubectl port-forward (nothing exposed). Alerts: visible in Grafana / Alertmanager (no receiver: POC).
```
Our alerts: `MyAppDown`, `MyAppHPAAtMax`, `MyAppHighRestarts`, `KarpenterNodePoolNearLimit`
(`monitoring/alerts/my-app.yaml`), plus the chart's standard Kubernetes alerts.

---

## 10. Environments

| | dev | staging | production |
|---|---|---|---|
| Where (POC) | Namespace in `platform-dev` | Namespace in `platform-dev` | Namespace in `platform-dev` |
| HPA min / max | 1 / 3 | 2 / 6 | 3 / 20 |
| Secret | `platform-dev/my-app/dev` | `…/staging` | `…/production` |
| URL | `http://<alb>/dev` | `/staging` | `/production` |
| Deployment | Automatic on every my-app merge | Released on purpose | Released on purpose + approval |

Production-grade phase: dedicated staging/production clusters (VPCs `10.1.0.0/16`, `10.2.0.0/16` reserved) from the
same modules, preferably one AWS account per environment.

---

## 11. Versions

| Component | Version |
|---|---|
| Kubernetes (EKS) | 1.36 |
| Terraform | 1.16.5 (AWS provider ~> 6.0; modules: eks ~> 21, vpc ~> 6, iam ~> 6) |
| ArgoCD | v3.5.4 (chart 10.10.1) |
| AWS Load Balancer Controller | chart 3.6.0 |
| Karpenter | 1.15.0 |
| External Secrets Operator | 2.12.0 |
| Kyverno | v1.19.1 (chart 3.9.1) |
| kube-prometheus-stack | 92.3.1 · Loki 3.6 (chart 7.3.0) · Alloy v1.20.1 (chart 1.13.1) |
| my-app runtime | Node.js 22, `gcr.io/distroless/nodejs22-debian13:nonroot` |
