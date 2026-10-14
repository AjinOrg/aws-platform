# Assumptions, Trade-offs and Known Limitations (as built)

Design reference: proposal v1.6, Sections 14 and 15. This version records what the POC actually assumes and
accepts. Production-grade items: README §11 "POC scope".

## Assumptions

| Area | Assumption (as built) |
|---|---|
| AWS | Account `471112815218`, region **ap-south-1** (design: us-east-1). Admin access for the bootstrap |
| Local access | Temporary IAM user access keys (profile `task`) for the bootstrap and first build; to be deleted (SSO preferred) |
| Source control | GitHub organization `AjinOrg`, **public** repositories (free rulesets and environment reviewers) |
| GitHub | A GitHub App (`ajinorg-deployer`) installed on `aws-platform`; Actions allowed in the organization |
| Application | Stateless, `/healthz` + `/readyz`, non-root, read-only filesystem, secrets read from files |
| DNS / TLS | **No domain**: HTTP on the load balancer's own address (HTTPS needs an ACM certificate) |
| Clusters | One EKS cluster with dev, staging and production namespaces (dedicated clusters later) |
| Usage | POC used during working hours; stopped when not in use |

## Trade-offs (design)

| Decision | Benefit | Trade-off |
|---|---|---|
| EKS | Managed control plane | Control-plane cost per cluster |
| Kyverno | YAML policies, same in CI and cluster | Less expressive than Rego; `ClusterPolicy` deprecated in 1.19 (migrate to `ValidatingPolicy`) |
| ArgoCD | UI, self-heal | More resources than Flux |
| External Secrets | AWS-native, no servers | No dynamic credentials |
| Loki | Light, cheap | Label-based search, no full-text index |
| Karpenter | Fast, cost-efficient | More tuning (see sizing lessons) |
| Separate repositories | Ownership, access control | Cross-repository automation (GitHub App) |
| Manual Terraform approval | No unreviewed infrastructure change | Changes wait for a reviewer |
| CloudFormation bootstrap | No local state | A second small IaC tool |

## Trade-offs (POC choices)

| Choice | Saves / gains | Accepted cost or risk | Production-grade |
|---|---|---|---|
| Stop/start Dev (destroy/rebuild) | ~$7/day while stopped | ~25–30 min to start; secret values, ECR images, ArgoCD/Grafana passwords recreated | Always-on environments |
| No interface VPC endpoints in Dev | ~$3/day | ECR/STS/Secrets Manager traffic via NAT (TLS, internet path, per-GB NAT cost) | Endpoints on |
| Spot for app and monitoring nodes | 60–90 % node cost | 2-minute interruptions (Karpenter drains); monitoring pods may restart | On-Demand app nodes in production; separate monitoring NodePool |
| One shared ALB, path-based | ~$1.10/day | Environments share one load balancer | Per-environment ALB / clusters, host-based routing |
| HTTP, no domain | No domain needed | Unencrypted between browser and ALB | ACM + Route53, HTTPS only |
| 2 Gi monitoring volumes, 2-day retention | Small, cheap | Short history | Larger volumes, 15–30 days, Loki on S3, or managed AMP/AMG |
| Port-forward for ArgoCD/Grafana | Nothing exposed | Needs cluster access | SSO + internal load balancer (prepared for ArgoCD, commented) |
| Alerts without receivers | Simple | Nobody is paged | Slack/email/PagerDuty via Alertmanager (secret from Secrets Manager) |
| Single admin + admin bypass (aws-platform) | Work can proceed alone | Own PRs merged without a second review | Second Code Owner; remove bypass; `prevent_self_review` |
| `al2023@latest` image, add-ons "most recent" | Always patched | Unplanned upgrades in unrelated plans | Pin AMI and add-on versions; upgrade by PR |
| CI tools and chart versions pinned; Actions by major tag | Reproducible | Actions not pinned to commit SHAs | Pin Actions to SHAs |
| 2 × t3.medium system nodes | Stable platform | ~$1.10/day more than 1 node | Sized per environment |

## Known limitations

| # | Limitation | Risk | Fix |
|---|---|---|---|
| 1 | One ClusterSecretStore and one IAM role read all environments' secrets | An ExternalSecret in dev could request production values | One role + store per environment, or Secrets Store CSI Driver with each app's role |
| 2 | Account root is a cluster admin (`cluster_admin_arns`) for console visibility | Root has unlimited power | Console via IAM user/SSO; remove the root ARN |
| 3 | Temporary IAM user access keys on a laptop | Long-lived credential | Delete after the last local Terraform run (now only the pipeline applies) |
| 4 | HPA-owned replicas are outside GitOps self-heal | Manual scale-to-0 stays | `MyAppDown` (detects); Kyverno `require-min-replicas` (prevents; ready on a branch) |
| 5 | Secret changes reach pods on the next External Secrets refresh (10 min, plus ~1–2 min for the kubelet) | Short delay | `force-sync` annotation (1–2 min) |
| 6 | Single region | Regional outage affects all environments | Multi-region (future) |
| 7 | Image signing not in scope | Unsigned images could be pushed by a compromised pipeline | Cosign + Kyverno image verification |
| 8 | App exposes no `/metrics` | Only platform metrics (CPU, memory, restarts, replicas) | Prometheus metrics in the app |
| 9 | SonarQube not active | No code-quality gate | Add `SONAR_TOKEN` (job ready), when application development starts |
| 10 | OWASP Dependency-Check inactive without `NVD_API_KEY` | `npm audit` only | Add the NVD key |

## Future improvements
Cosign signing + Kyverno verification · service mesh / mTLS · DAST against staging · multi-region failover ·
Kubecost / cost allocation · managed Prometheus/Grafana · per-environment AWS accounts.
