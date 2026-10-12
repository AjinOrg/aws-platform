# Karpenter and External Secrets: How They Work Here

How the two Day 4 add-ons work in this platform: what each one does, where it is installed, which files define
it, and read-only commands to look at it. Nothing in this document changes the cluster.

## Contents
- [Part A: Karpenter](#part-a-karpenter)
  - [What it is](#what-it-is)
  - [Where it is installed](#where-it-is-installed)
  - [How it works, step by step](#how-it-works-step-by-step)
  - [Which files do what](#which-files-do-what)
  - [How the names tie Terraform and GitOps together](#how-the-names-tie-terraform-and-gitops-together)
  - [Look at it (read-only)](#look-at-it-read-only)
- [Part B: External Secrets](#part-b-external-secrets)
  - [What it is](#what-it-is-1)
  - [Where the secrets are stored](#where-the-secrets-are-stored)
  - [The objects involved](#the-objects-involved)
  - [Check it (read-only)](#check-it-read-only)

---

## Part A: Karpenter

### What it is
The cluster has **2 fixed nodes** (the system node group, On-Demand). When applications need more room,
something must **add a machine**, and remove it when it is no longer needed. That is Karpenter.

```
Without Karpenter:  pod can't fit → stays "Pending" forever
With Karpenter:     pod can't fit → Karpenter sees it → asks AWS for a fitting EC2 Spot instance
                    → ~60 s later the node joins → pod starts
                    later: node empty → Karpenter terminates it → no more cost
```

### Where it is installed

| What | Where | Why there |
|---|---|---|
| Karpenter controller (2 pods) | Namespace `kube-system`, on the **system nodes** | It must never run on a node it manages (it could remove itself) |
| The nodes it creates | EC2 **Spot** instances in the **private subnets**, label `node-role: apps` | Where application pods run |
| Its AWS permissions | IAM role `platform-dev-karpenter` (EKS Pod Identity) | To launch and terminate EC2 instances |

```
EKS cluster platform-dev
│
├── System nodes (Terraform node group, On-Demand, 2 × t3.medium, label node-role=system)
│     ├── kube-system:      karpenter (2 pods) ── Pod Identity ──▶ IAM role platform-dev-karpenter
│     ├── kube-system:      aws-load-balancer-controller
│     ├── external-secrets: external-secrets operator
│     └── argocd:           ArgoCD
│
└── App nodes (created by Karpenter, Spot, label node-role=apps)   ← none until a pod needs one
      └── dev / staging / production: my-app pods (Day 5)
```

### How it works, step by step

```
1. A pod is created with nodeSelector "node-role: apps"
2. Kubernetes scheduler: no node has that label/room → pod = Pending
3. Karpenter (watching Pending pods) reads the NodePool "apps":
      allowed: Spot, t/m/c families, 2–4 vCPU, total limit 8 vCPU
4. It picks the cheapest Spot instance that fits the pod
5. It builds it per the EC2NodeClass "default":
      AL2023 image, private subnet, node security group, role platform-dev-karpenter-node,
      encrypted 30 GB disk, IMDSv2
6. EC2 boots → node registers with EKS (allowed by the access entry) → pod starts
7. Later:
   - pod deleted → node empty for 1 min → Karpenter terminates it        (consolidation)
   - AWS reclaims the Spot instance → 2-min warning arrives via SQS queue
     → Karpenter moves pods away first                                   (interruption handling)
   - node older than 7 days → replaced with a fresh image                 (expireAfter)
```

Spot interruption path:
```
AWS: "I'm taking back instance i-abc in 2 minutes"
   → EventBridge rule → SQS queue platform-dev-karpenter
   → Karpenter reads it → marks the node unschedulable → moves pods to other nodes
     → launches a replacement if needed → the old node is gone, the app kept running
```

### Which files do what
Karpenter is split between **Terraform** (AWS permissions) and **GitOps** (the software and its rules).

| # | File | Tool | Details it holds | Used for |
|---|---|---|---|---|
| 1 | `terraform/modules/eks/main.tf` → `module "karpenter"` | Terraform | Controller role `platform-dev-karpenter`; Pod Identity link `kube-system/karpenter`; node role `platform-dev-karpenter-node`; node access entry; SQS queue `platform-dev-karpenter` + EventBridge rules | **Permission** to launch EC2, **permission** for new nodes to join, the **Spot warning** channel |
| 2 | `terraform/modules/eks/main.tf` → add-on `eks-pod-identity-agent` | Terraform | Agent that hands credentials to Karpenter's pod | How the pod **receives** the role's credentials |
| 3 | `terraform/modules/vpc/main.tf` → `private_subnet_tags` | Terraform | Tag `karpenter.sh/discovery = platform-dev` on private subnets | **Which subnets** nodes go into |
| 4 | `terraform/modules/eks/main.tf` → `node_security_group_tags` | Terraform | Same tag on the node security group | **Which security group** nodes get |
| 5 | `gitops/platform/repositories.yaml` | ArgoCD | `public.ecr.aws/karpenter` (OCI) | **Where** ArgoCD downloads the chart |
| 6 | `gitops/platform/projects.yaml` | ArgoCD | That registry in `sourceRepos` | **Permission** for ArgoCD to use that source |
| 7 | `gitops/platform/karpenter.yaml` | ArgoCD | Chart 1.15.0; `clusterName: platform-dev`; `interruptionQueue: platform-dev-karpenter`; service account `karpenter`; `AWS_REGION`; system nodes; destination `kube-system` | **Installs the controller** |
| 8 | `gitops/platform/karpenter-nodes.yaml` | ArgoCD | Points at `gitops/platform-config/karpenter/` | Applies the two rule files below |
| 9 | `gitops/platform-config/karpenter/ec2nodeclass.yaml` | Karpenter | Image `al2023@latest`; subnets and security group *by tag*; node role; `maxPods 110`; IMDSv2; encrypted disk | **HOW** a node is built |
| 10 | `gitops/platform-config/karpenter/nodepool.yaml` | Karpenter | Spot only; t/m/c; 2–4 vCPU; limit 8 vCPU / 32 Gi; consolidation; `expireAfter 168h`; label `node-role: apps` | **WHICH** nodes are allowed, and how many |

### How the names tie Terraform and GitOps together

```
Terraform creates                         GitOps refers to it
─────────────────                         ─────────────────────
role  platform-dev-karpenter-node   ←──   ec2nodeclass.yaml  role:
queue platform-dev-karpenter        ←──   karpenter.yaml     interruptionQueue:
Pod Identity kube-system/karpenter  ←──   karpenter.yaml     destination kube-system + SA karpenter
tag   karpenter.sh/discovery        ←──   ec2nodeclass.yaml  subnet/securityGroup SelectorTerms
```
If any of these differ, Karpenter fails ("no subnets found", "AccessDenied", nodes that never join).

### Look at it (read-only)
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide   # controller: 2 pods on system nodes
kubectl get ec2nodeclass,nodepool                                          # the two rule objects
kubectl describe ec2nodeclass default | sed -n '/Status:/,$p'               # resolved subnets, SGs, AMI IDs
kubectl get nodeclaims                                                     # nodes Karpenter launched (empty until needed)
kubectl get nodes -L node-role,karpenter.sh/capacity-type                   # system/apps, spot/on-demand
kubectl logs -n kube-system deploy/karpenter --tail=20                     # what it is doing
```
An empty `kubectl get nodeclaims` is normal: no pod has asked for `node-role: apps` yet, so Karpenter has
launched nothing and costs nothing extra.

---

## Part B: External Secrets

### What it is
The application needs secrets (passwords, API keys). They must **never be in Git**. External Secrets Operator
(ESO) copies them from AWS Secrets Manager into Kubernetes Secrets that pods can use.

```
AWS Secrets Manager                         Kubernetes cluster
(the real, only copy)                       (a synced copy the pod can read)
──────────────────────                      ─────────────────────────────────
platform-dev/my-app/dev       ──┐
platform-dev/my-app/staging   ──┼── ESO reads (IRSA role) ──▶  Secret "my-app" in namespace dev
platform-dev/my-app/production──┘   every hour / on change     Secret "my-app" in namespace staging ...
   encrypted with KMS key                                         → mounted into the pod as env vars
   alias/platform-dev-secrets
```

### Where the secrets are stored

| Place | What is there | The source? |
|---|---|---|
| **AWS Secrets Manager** | `platform-dev/my-app/{dev,staging,production}`, encrypted with KMS | ✅ **Yes, the only real copy.** Values are set here with the CLI |
| Kubernetes Secret (in dev/staging/production) | A copy made by ESO, encrypted at rest by EKS's KMS key | No: re-created from AWS; delete it and ESO restores it |
| Git | Only the *name* of the secret | No values, ever |
| Terraform state | Only the empty secret *definition* | No values (they are set with the CLI) |

### The objects involved

| Object | Defined in | Says |
|---|---|---|
| IRSA role `platform-dev-external-secrets` | `terraform/modules/iam/main.tf` | ESO may **read only these 3 secrets** and **decrypt only with their key** |
| Secrets + KMS key | `terraform/modules/secrets/main.tf` | The 3 empty secrets and `alias/platform-dev-secrets` |
| ESO controller (3 pods) | `gitops/platform/external-secrets.yaml` → namespace `external-secrets` | Installs the operator; its service account is linked to the IRSA role |
| **ClusterSecretStore** `aws-secrets-manager` | `gitops/platform-config/external-secrets/cluster-secret-store.yaml` | **"How to reach the store":** Secrets Manager in ap-south-1, ESO's own role, **only for** namespaces dev, staging, production |
| **ExternalSecret** (Day 5) | The app's Helm chart | **"What to copy":** `platform-dev/my-app/dev` → Secret `my-app` in namespace `dev` |

```
ClusterSecretStore "aws-secrets-manager"      = the CONNECTION   (exists now)
ExternalSecret     "my-app" (per namespace)   = the REQUEST      (arrives with the app, Day 5)
Secret             "my-app" (per namespace)   = the RESULT       (created by ESO from the request)
```
Until an ExternalSecret exists, nothing is copied: the cluster holds no application secrets yet.

### Check it (read-only)

**1. Does the connection work?**
```bash
kubectl get clustersecretstore aws-secrets-manager          # STATUS Valid, READY True
kubectl describe clustersecretstore aws-secrets-manager | sed -n '/Status:/,$p'
```

**2. What is in AWS (the source)?**
```bash
aws secretsmanager list-secrets \
  --query "SecretList[?starts_with(Name,'platform-dev/')].[Name,LastChangedDate]" --output table
aws secretsmanager get-secret-value --secret-id platform-dev/my-app/dev --query SecretString --output text
# "ResourceNotFoundException ... no secret value" = the secret exists but no value was stored yet
```

**3. What has ESO copied into the cluster (after Day 5 or the Day 4 test)?**
```bash
kubectl get externalsecrets -A                  # STATUS SecretSynced = copied OK
kubectl get secret -n dev                       # the resulting Kubernetes Secret(s)
kubectl get secret my-app -n dev -o jsonpath='{.data}' | head -c 200; echo   # base64, not encrypted
```

**4. Who may read the secrets in AWS?**
```bash
aws iam list-attached-role-policies --role-name platform-dev-external-secrets
# then, with the PolicyArn from above:
aws iam get-policy --policy-arn <PolicyArn> --query Policy.DefaultVersionId --output text
aws iam get-policy-version --policy-arn <PolicyArn> --version-id <v1> --query PolicyVersion.Document
# lists exactly the 3 secret ARNs and the one KMS key
```

**About base64:** a Kubernetes Secret value is only *encoded* (base64), not encrypted. Anyone who can
`kubectl get secret` in that namespace can read it. That is why cluster access is restricted, Secrets are
encrypted at rest with KMS, and developers get read-only access without Secret permissions later.
