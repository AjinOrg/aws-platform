# Operational Runbook (as built)

Commands for running the POC platform. Namespaces: `dev`, `staging`, `production` (app), `argocd`, `kube-system`,
`external-secrets`, `kyverno`, `monitoring`. Cluster `platform-dev`, region `ap-south-1`.

> **Rule:** the cluster is managed by ArgoCD with self-heal. A manual `kubectl` change to anything that is in Git is
> reverted within ~1 minute. Lasting changes go through a pull request in `aws-platform`.
> Exception: replica counts are owned by the HPA (not in Git) - see [Scale-to-zero](#app-scaled-to-0).

```bash
export AWS_PROFILE=task AWS_REGION=ap-south-1
aws eks update-kubeconfig --name platform-dev --region ap-south-1
```

## Contents
[Start / stop](#start--stop) · [Daily checks](#daily-checks) · [Access](#access) · [Releases and rollback](#releases-and-rollback) ·
[Infrastructure](#infrastructure-changes) · [Secrets](#secrets) · [Scaling](#scaling) · [Policies](#policies) ·
[Troubleshooting](#troubleshooting) · [Emergency](#emergency-procedures)

---

## Start / stop
```bash
bash scripts/platform-status.sh     # RUNNING or STOPPED, what costs money
bash scripts/platform-stop.sh       # ~15–20 min: ALBs, Karpenter nodes, PVC volumes, ArgoCD, terraform destroy
bash scripts/platform-start.sh      # ~25–30 min: terraform apply, ArgoCD, root app, Grafana admin secret
```
After a start: store the 3 secret values, re-run the my-app pipeline (ECR is empty), read the new ArgoCD and
Grafana passwords (the script prints the commands). Release tags present in `values-*.yaml` must exist in ECR.

## Daily checks
```bash
kubectl get nodes -L node-role,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
kubectl get applications -n argocd                  # all Synced / Healthy
kubectl get pods -A | grep -vE "Running|Completed"  # nothing listed
kubectl get clusterpolicy                           # 6 policies READY True (7 after require-min-replicas)
kubectl get pvc -n monitoring                       # 4 Bound
ALB=$(kubectl get ingress my-app -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for e in dev staging production; do printf '%-11s ' $e; curl -s http://$ALB/$e/my-app | grep -o '"version":"[^"]*"'; done
```
URLs: `http://<alb>/<environment>/<service>` (one shared ALB, IngressGroup `apps`, for every service).

## Access
| Tool | Command | URL / login |
|---|---|---|
| ArgoCD | `kubectl port-forward svc/argocd-server -n argocd 8080:443` | https://localhost:8080, `admin` (password changed after install) |
| Grafana | `kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80` | http://localhost:3000, `admin`, password: `kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Prometheus | `kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090` | http://localhost:9090 (alerts: `/alerts`) |
| Alertmanager | `kubectl port-forward svc/monitoring-kube-prometheus-alertmanager -n monitoring 9093:9093` | http://localhost:9093 (silences) |
| Node shell | `aws ssm start-session --target <instance-id>` | No SSH |

## Releases and rollback
Releases are run by the release team in **AjinOrg/helm-chart** (its README has the details); listed here for operators.

| Action | How |
|---|---|
| Deploy to dev | Merge a PR in the service repo (e.g. `my-app`): automatic (bot PR in helm-chart → auto-merge → ArgoCD → `verify.yaml`) |
| Release to staging / production | In helm-chart: `bash scripts/release.sh` (menu: service, environment, tag), or Actions → **release** → Run workflow. Production PR: approve, then merge |
| Roll back | helm-chart `scripts/release.sh` → pick the previous tag (it has run there before) → confirm. Or revert the deployment PR |
| Check what runs where | In helm-chart: `grep -H 'tag:' apps/*/values-*.yaml`, and the `curl` loop above |
| Force ArgoCD to look now | ArgoCD UI → Refresh, or `argocd app get <app> --refresh` (otherwise ≤ 60 s) |

A release is refused when the tag never ran in the previous environment, is missing from ECR, or already runs there.

## Infrastructure changes
- **Normal change:** PR under `terraform/` → read the plan comment (or download `tfplan-dev-readable-<run>` →
  `tfplan.txt`) → merge → Actions → terraform → **Review deployments** → approve → applied.
- **"Saved plan is stale":** something changed between plan and apply → Actions → terraform → **Run workflow** on main.
- **Stuck state lock** (cancelled run): `terraform -chdir=terraform/environments/dev force-unlock <LOCK_ID>` - only when
  no run is in progress.
- **Earlier state version:** `aws s3api list-object-versions --bucket aws-platform-tfstate-471112815218 --prefix aws-platform/dev/terraform.tfstate`
- **Bootstrap stack:** change parameters only by **updating** it with a change set (README §8, "Changing a
  parameter later"); check drift: `aws cloudformation detect-stack-drift --stack-name aws-platform-bootstrap`.

## Secrets
```bash
# set / rotate a value (prefer a file: values in shell history are a leak)
aws secretsmanager put-secret-value --secret-id platform-dev/my-app/dev --secret-string file://secret.json
# push it to the cluster now instead of within 10 min (then ~1–2 min until the file in the pod changes)
kubectl annotate externalsecret my-app -n dev force-sync=$(date +%s) --overwrite
kubectl get externalsecret my-app -n dev            # SecretSynced
kubectl get clustersecretstore aws-secrets-manager  # READY True
```
The app reads the mounted files on every use: no restart needed.

## Scaling
```bash
kubectl get hpa -A                         # current / desired / min / max
kubectl get nodepool apps -o jsonpath='{.spec.limits}{"\n"}'
kubectl get nodeclaims                     # Karpenter's nodes
kubectl logs -n kube-system deploy/karpenter --tail=50
```
Change replica ranges in helm-chart `apps/<service>/values-<env>.yaml` (PR, release team). Change node limits/sizes in
`gitops/platform-config/karpenter/nodepool.yaml` (PR).

## Policies
```bash
kubectl get policyreport -A                         # compliance of running workloads
kubectl apply -f demo/bad-root.yaml                 # expected: rejected (demo)
kyverno apply policies/kyverno --resource <file>    # test a manifest locally (CLI 1.19.1)
```

---

## Troubleshooting
| Symptom | Likely cause | Check / fix |
|---|---|---|
| `kubectl` hangs / times out | Your public IP changed (API allows one /32) | `curl -s https://checkip.amazonaws.com` → update `admin_cidrs` in `terraform.tfvars` → Terraform PR |
| Pod `Pending`, Karpenter "exceed limits for nodepool" | NodePool `apps` limit reached | Raise `limits` in `nodepool.yaml`; `KarpenterNodePoolNearLimit` warns earlier |
| Pod `Pending`, "didn't match PersistentVolume's node affinity" | Its EBS volume is in another AZ and no node there | Karpenter launches one in that AZ if the limit allows; check `kubectl get nodeclaims` |
| Pod restarting, probes "connection refused", tiny nodes | Missing resource **requests** → Karpenter picked tiny nodes | Add requests; NodePool minimum size (≥ ~4 GiB) |
| Stateful pod keeps moving | Karpenter consolidation | `karpenter.sh/do-not-disrupt: "true"` on the pod |
| App `OutOfSync` forever, diff shows `labels: {}` / `annotations: {}` | API server drops empty maps from a chart template | Render real values (see `kyverno.yaml`, `kyverno-api.labels`) |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Role trust ≠ GitHub `sub` (immutable subject) | Compare role condition with `gh api repos/AjinOrg/<repo>/actions/oidc/customization/sub` |
| Release refused "never ran in dev" | Tag not deployed to the previous environment | Release it there first |
| `ImagePullBackOff` after a start | ECR is empty after a rebuild | Re-run the my-app pipeline; release that tag |
| ExternalSecret not syncing | Value missing in Secrets Manager / store not ready | `kubectl describe externalsecret my-app -n <env>`; put the value |
| ArgoCD app `Unknown`/error after adding a chart | Chart source not in AppProject `sourceRepos` / registry not in `repositories.yaml` | Add both (PR) |
| ArgoCD `Unknown` everywhere, "failed to load open api schema … unable to handle the request", while `kubectl` works | An aggregated API publishes a schema the API server cannot serve as **protobuf** (ArgoCD reads protobuf, kubectl JSON). 2026-10-16: metrics-server add-on `v0.9.0-eksbuild.12` | Test: `kubectl proxy` + `curl -H 'Accept: application/com.github.proto-openapi.spec.v2@v1.0+protobuf' localhost:8001/openapi/v2` (503 = broken, JSON still 200). Now: `kubectl delete apiservice v1beta1.metrics.k8s.io` → test gives 200 → restart `argocd-application-controller` (HPAs pause scaling meanwhile). Fix: install **another** add-on version (`aws eks update-addon … --addon-version <v> --resolve-conflicts OVERWRITE`), repeat the test, pin the passing version in `terraform/modules/eks/main.tf`. Never "restore" the same version: ArgoCD breaks again at its next reload |
| Application `root` OutOfSync, diff = `pre-delete-finalizer.argocd.argoproj.io` on `kyverno` | ArgoCD adds these finalizers for a chart's pre-delete hook (Kyverno `webhooksCleanup`) | Expected; `root` ignores them (`ignoreDifferences` in `gitops/bootstrap/root-app.yaml`, applied by hand) |
| Service app missing / `<service>-<env>` not created | Folder or values file missing in helm-chart, or environment not allowed by AppProject `apps` | `kubectl describe applicationset microservices -n argocd` (conditions) |
| Destroy hangs on VPC / security groups | Leftover ALB or `k8s-*` security group | `scripts/platform-status.sh`; delete leftovers; run stop again |

### App scaled to 0
Will be blocked by Kyverno `require-min-replicas` (branch `policy/require-min-replicas`, not merged yet). Until then,
or if it happens anyway: `MyAppDown` fires;
recover with `kubectl scale deploy my-app -n <env> --replicas=1` (the HPA takes over).

---

## Emergency procedures
| Need | How |
|---|---|
| A policy blocks something urgent | Kyverno `PolicyException` (namespaced, reviewed) or change the policy's `failureAction` to `Audit` in a PR; revert afterwards. A `kubectl` edit is reverted by self-heal |
| Pause automatic sync of one app | Add-ons: `argocd app set <app> --sync-policy none`. Service apps are generated by the ApplicationSet `microservices` (it rewrites them): change `gitops/apps/microservices.yaml` in a PR |
| Silence an alert during maintenance | Alertmanager UI → Silence |
| Replace a bad node | `kubectl delete nodeclaim <name>` (Karpenter replaces it) |
| Force-delete a stuck pod | `kubectl delete pod <pod> -n <ns> --force --grace-period=0` |
| Stop all spending now | `bash scripts/platform-stop.sh` |
