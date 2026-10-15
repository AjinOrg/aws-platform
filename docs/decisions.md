# Key Technical Decisions (as built)

Decisions 1–13 come from the design (proposal v1.6, Section 13), updated where the build differs.
Decisions 14–27 were made during the build. Each entry: decision, why, alternative.

## Contents
- From the design: [1 IaC](#1-infrastructure-as-code-terraform-modules--one-folder-per-environment) ·
  [2 Bootstrap](#2-state-bootstrap-cloudformation) · [3 Locking](#3-state-locking-s3-native-locking) ·
  [4 EKS](#4-managed-kubernetes-amazon-eks) · [5 Repositories](#5-repositories-separate-application-and-platform) ·
  [6 GitOps](#6-deployment-argocd-gitops-with-helm) · [7 CI/CD](#7-cicd-github-actions-oidc-and-a-github-app) ·
  [8 Terraform pipeline](#8-infrastructure-delivery-terraform-pipeline-with-approval) · [9 Kyverno](#9-policy-engine-kyverno) ·
  [10 Secrets](#10-secrets-secrets-manager--external-secrets) · [11 Karpenter](#11-node-scaling-karpenter--hpa) ·
  [12 Scanners](#12-scanning-tools) · [13 Observability](#13-observability-prometheus--grafana--loki)
- From the build: [14–27](#14-github-oidc-trust-on-the-immutable-subject-owner-and-repository-ids)

---

## 1. Infrastructure as Code: Terraform modules + one folder per environment
**Decision:** Our own modules (`vpc`, `eks`, `ecr`, `iam`, `secrets`); `vpc`, `eks`, `iam` wrap the community
`terraform-aws-modules`, `ecr` and `secrets` are plain resources. One folder per environment (`environments/dev`).
**Why:** write once, reuse per environment; differences only in `terraform.tfvars`; reviewable plans; the community
modules replace dozens of easy-to-get-wrong resources, our wrapper holds only our decisions.
**Alternative:** CDK, CloudFormation. **Not chosen:** smaller ecosystem.

## 2. State bootstrap: CloudFormation
**Decision:** `bootstrap/state-backend.yaml` (stack `aws-platform-bootstrap`): state bucket, KMS key, GitHub OIDC
provider, three pipeline roles. Termination protection; bucket and key retained.
**Why:** Terraform's bucket must exist before Terraform; CloudFormation keeps its own state in AWS.
**Alternative:** local Terraform bootstrap. **Not chosen:** its state starts on a laptop.
Parameters are changed by **updating** the stack with a change set (README §8), never by recreating it.

## 3. State locking: S3 native locking
**Decision:** `use_lockfile = true`; no DynamoDB table. **Why:** nothing extra; DynamoDB locking is deprecated.

## 4. Managed Kubernetes: Amazon EKS
**Decision:** EKS 1.36; a small On-Demand system node group (platform add-ons) + Karpenter Spot nodes (apps,
monitoring). **Why:** managed control plane, AWS integrations, IRSA/Pod Identity.
**Alternative:** self-managed, ECS. **Not chosen:** operational effort / no Kubernetes ecosystem.

## 5. Repositories: separate application and platform
**Decision:** `AjinOrg/my-app` and `AjinOrg/aws-platform` (GitHub organization `AjinOrg`).
**Why:** ownership and access control; independent pipelines; future apps reuse the platform.
**Alternative:** monorepo. **Not chosen:** weaker access control, mixed pipelines.

## 6. Deployment: ArgoCD (GitOps) with Helm
**Decision:** ArgoCD (installed once with Helm) + app-of-apps (`root-app.yaml`); add-ons as Applications in project
`platform`; my-app via an ApplicationSet (one Application per environment) in the stricter project `apps`.
**Why:** Git is the source of truth; self-heal; rollback = revert; clear UI. AppProjects restrict sources/destinations.
**Alternative:** FluxCD, kubectl from CI. **Not chosen:** weaker UI / no drift correction / CI needs cluster access.

## 7. CI/CD: GitHub Actions, OIDC and a GitHub App
**Decision:** GitHub Actions; GitHub OIDC for AWS; GitHub App `ajinorg-deployer` for cross-repository PRs.
**Why:** no CI servers; no AWS keys or personal tokens in GitHub; PRs opened with the App token trigger checks
(PRs opened with `GITHUB_TOKEN` would not).
**Alternative:** Jenkins, personal access tokens. **Not chosen:** infrastructure to run / long-lived personal tokens.

## 8. Infrastructure delivery: Terraform pipeline with approval
**Decision:** `terraform.yaml`: PR → read-only plan as a PR comment (+ downloadable `tfplan.txt`); main → saved plan
→ GitHub Environment `terraform-apply` (required reviewer) → apply role → apply the saved plan.
**Why:** no unreviewed change; exactly the approved plan is applied (stale plans are refused); apply credentials exist
only after approval. **Alternative:** laptop `terraform apply`. **Not chosen:** not reviewed, repeatable or auditable.

## 9. Policy engine: Kyverno
**Decision:** Kyverno (v1.19.1) in the cluster, Enforce, 6 policies (7th ready on a branch) scoped to dev/staging/production; the same files
run in CI with the Kyverno CLI (same version); Pod Security Admission `restricted` as a baseline.
**Why:** YAML policies; one set of rules for CI and cluster. **Alternative:** OPA Gatekeeper. **Not chosen:** Rego.
Note: `ClusterPolicy` is deprecated in Kyverno 1.19 in favour of `ValidatingPolicy` (CEL): migration is planned.

## 10. Secrets: Secrets Manager + External Secrets
**Decision:** one Secrets Manager secret (JSON) per namespace, KMS-encrypted, created empty by Terraform (values set
with the CLI); External Secrets (IRSA) copies it into a Kubernetes Secret, mounted as a volume.
**Why:** no secrets in Git or state; AWS-native. **Known POC limitation:** one shared store/role for all environments
([trade-offs](trade-offs.md#known-limitations)). **Alternative:** Vault, Sealed Secrets, Secrets Store CSI Driver
(documented in [karpenter-and-external-secrets.md](karpenter-and-external-secrets.md#choosing-how-pods-get-secrets)).

## 11. Node scaling: Karpenter + HPA
**Decision:** Karpenter NodePool `apps` (Spot) for app and monitoring pods; HPA for my-app replicas.
**Why:** fast, picks instance types per workload, consolidates. **Alternative:** Cluster Autoscaler. **Not chosen:** slower.

## 12. Scanning tools
| Area | Tool | Where |
|---|---|---|
| Secrets | Gitleaks 8.30.1 | Both repositories, full history |
| Dependencies | npm audit + OWASP Dependency-Check 13.0.0 (needs `NVD_API_KEY`) | my-app |
| Images | Trivy 0.75.0 (fs + image) + ECR scan on push | my-app |
| IaC / chart | Checkov 3.3.27 (`.checkov.yaml`: skipped checks with reasons) | aws-platform |
| Manifest schema | kubeconform 0.8.0 (+ CRD catalog) | aws-platform |
| Policies | Kyverno CLI 1.19.1 | Both |
| Code quality | SonarQube Cloud (Phase 2: job ready) | my-app |

## 13. Observability: Prometheus + Grafana + Loki
**Decision:** kube-prometheus-stack + Loki (single binary) + Alloy; alerts and dashboards as code in `monitoring/`.
**Why:** standard, one Grafana for metrics and logs, Loki is light. **Alternative:** ELK. **Not chosen:** heavier.

---

## 14. GitHub OIDC trust on the immutable subject (owner and repository IDs)
**Decision:** role trust conditions use `repo:AjinOrg@339973007/<repo>@<repo-id>:…` (template parameters
`GitHubOrgId`, `AppRepoId`, `PlatformRepoId`). **Why:** GitHub sends this format for these repositories; IDs, unlike
names, are never reused, so a recreated repository with the same name cannot assume the roles.
**Found by:** `Not authorized to perform sts:AssumeRoleWithWebIdentity` on the first ECR push.

## 15. Dev deploys automatically; staging and production are released on purpose
**Decision:** every my-app merge reaches dev (bot PR, auto-merge, smoke test); staging/production move only when a
person starts `release.yaml` (form) or `scripts/release.sh` (menu) and picks a tag that already ran in the previous
environment; production additionally needs a Code Owner approval.
**Why:** approve releases, not commits: developers never wait, people decide only where a decision is needed.
**Alternative:** automatic promotion after smoke tests. **Not chosen:** the team wants a deliberate staging release.

## 16. Approvals by file: rulesets + CODEOWNERS
**Decision:** rulesets on main (PR required, required checks, no force push); "require review from Code Owners" with
0 other approvals; `values-dev.yaml` and `values-staging.yaml` have no owner, `values-production.yaml` and
infrastructure do. Admin bypass (via PR) on aws-platform only, until a second Code Owner exists.
**Why:** one mechanism for "no human for dev, human for production"; bots never change production alone.

## 17. Lighter main run + "branch must be up to date" (my-app)
**Decision:** checks run on PRs only; main builds, scans the image, pushes and opens the dev PR; the my-app ruleset
requires branches to be up to date before merge. **Why:** each check once; what was tested is what lands on main.
**Alternative:** merge queue. **Later:** when many developers merge daily.

## 18. Smoke tests after every deployment (`verify.yaml`)
**Decision:** after a values file changes, wait until the environment serves the new tag, then test version,
environment, mounted secret and 20 requests. **Why:** "deployed" is proven, not assumed. Finds the ALB by its tag with
the read-only role (its address changes on every rebuild).

## 19. One shared load balancer, path-based
**Decision:** IngressGroup `apps`: one ALB for every service and environment, path `/<env>/<service>`
(e.g. `/dev/my-app`). Until 2026-10-15: IngressGroup `my-app` with `/dev`, `/staging`, `/production`.
**Why:** one ALB instead of one per service and environment (cost); no domain, so host-based routing is not
possible. HTTPS later.

## 20. Helm charts over OCI
**Decision:** ArgoCD, Karpenter, External Secrets, Kyverno, kube-prometheus-stack and Loki charts from OCI
registries (ghcr.io, public ECR). **Why:** the https chart repositories download from GitHub release assets, which timed
out on the office network. Alloy has no OCI chart: https repository (fetched by ArgoCD inside AWS).

## 21. EKS Pod Identity for Karpenter and the EBS CSI driver; IRSA for the rest
**Decision:** Pod Identity where the module supports only it (Karpenter) or offers it directly (EBS CSI add-on).
**Why:** same security result (short-lived credentials per service account). Both mechanisms are documented.

## 22. Fixed KMS key administrators
**Decision:** `kms_key_administrators` lists the apply role and the admin user. **Why:** the EKS module's default is
"whoever runs Terraform", which would flip the key policy between laptop, plan role and apply role on every run.

## 23. Replicas owned by the HPA; scale-to-zero blocked by Kyverno
**Decision:** no `replicas` in the chart (HPA owns it); Kyverno `require-min-replicas` blocks scaling app Deployments
to 0 (incl. the `deployments/scale` subresource); `MyAppDown` alerts if it happens anyway. **Status:** the policy is on
branch `policy/require-min-replicas`, merged after the client demo of scaling down.
**Why:** ArgoCD self-heal compares only fields in Git and the HPA does not scale up from 0, so scale-to-0 would stay.

## 24. Monitoring sizing and stability
**Decision:** monitoring on Karpenter Spot nodes; requests/limits for every monitoring pod; nodes ≥ ~4 GiB (no
nano/micro/small); `karpenter.sh/do-not-disrupt` on the stateful pods; consolidation after 5 min; NodePool limit
16 vCPU. **Why:** Karpenter sizes nodes from requests; without them it chose 1 GiB nodes and Grafana could not start;
zonal volumes need a node in their AZ. **Later:** a separate On-Demand NodePool for monitoring.

## 25. POC cost model: stop/start
**Decision:** `scripts/platform-stop.sh` (removes ALBs, Karpenter nodes, PVC volumes, then `terraform destroy`) and
`platform-start.sh` (Terraform → ArgoCD → everything from Git); interface endpoints off; ECR `force_delete` and
secret recovery window 0 in Dev. **Why:** EKS and NAT cannot be paused; stopped ≈ cents/day.

## 26. ArgoCD polling 60 s
**Decision:** `timeout.reconciliation: 60s` (was 180 s). **Why:** observed 3–4 min sync delays; webhooks need ArgoCD
reachable from GitHub (Phase 2).

## 27. Two system nodes kept
**Decision:** 2 × t3.medium, not 1. **Why:** 1 node saves ~$1.10/day but Karpenter's 2nd replica cannot schedule and
ArgoCD/Karpenter/ALB controller share one point of failure; stop/start saves far more.

## 28. Service charts and values in their own repository (`AjinOrg/helm-chart`)
**Decision (2026-10-15, after the management review):** three repositories, three owners: infrastructure and
guardrails (`aws-platform`, infra team), how services run (`helm-chart`, release team), service code (`my-app` and
future services, developers). `aws-platform` keeps the AppProject `apps` and the ApplicationSet `microservices`, so the
infra team still decides where services may run; the release team decides what runs.
**Why:** each team changes only what it owns; release work no longer needs platform approvals.

## 29. One shared chart for all services, versions pinned per environment
**Decision:** `charts/microservice` in helm-chart serves every service (values per service and environment); no
umbrella chart. Each chart change is tagged `chart-v<version>`; dev runs `main`, staging and production pin a tag in
`environments/<env>.yaml`. **Why:** services release and roll back independently (one Application each); a chart
change cannot reach production before it ran in dev and staging. **Alternative:** umbrella chart (all services of an
environment as one release). **Not chosen:** one service's change or rollback would re-release all of them.
