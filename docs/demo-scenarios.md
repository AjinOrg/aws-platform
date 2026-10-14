# Demo Scenarios (as built)

What the platform can show, with the real files and names. Status: ✅ shown in this build · ⏳ ready, not yet run ·
🔜 being built. Before a demo: `bash scripts/platform-status.sh` (RUNNING) and the daily checks in the
[runbook](runbook.md#daily-checks).

| # | Scenario | Shows | Status |
|---|---|---|---|
| 1 | Change reaches dev automatically | CI checks → ECR (OIDC) → bot PR → ArgoCD → smoke test | ✅ |
| 2 | Release to staging and production | Pick a tested tag; production needs approval | ✅ |
| 3 | Infrastructure change with approval | Plan comment → approval gate → apply | ✅ |
| 4 | Blocked in the cluster: privileged, root, registry, limits | Kyverno admission | ✅ |
| 5 | Blocked: scale to zero | Kyverno `require-min-replicas` | ⏳ (policy on a branch, after the client demo) |
| 6 | Blocked in CI: Docker Hub image in values | Kyverno CLI in platform-ci | ⏳ |
| 7 | Blocked in CI: vulnerable image | Trivy | ✅ (real OpenSSL CVEs) |
| 8 | Blocked in CI: secret in code | Gitleaks | ⏳ |
| 9 | Blocked in CI: insecure infrastructure | Checkov | ⏳ |
| 10 | GitOps self-heal | ArgoCD restores drift | ✅ |
| 11 | Monitoring and alerting | Dashboard, logs, `MyAppDown` | ✅ |
| 12 | Autoscaling under load | HPA + Karpenter, watched in Grafana | 🔜 (POC item 4) |

`ALB=$(kubectl get ingress my-app -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')`

---

## 1. Change reaches dev automatically
```bash
cd ~/workspace/Task/my-app && git checkout main && git pull && git checkout -b demo/change
# make a visible change, e.g. in src/app.js
git commit -am "demo: visible change" && git push -u origin demo/change
gh pr create --fill && gh pr checks --watch        # Gitleaks, tests, deps, Trivy fs, build+Trivy image+Kyverno
gh pr merge --squash --delete-branch
gh run watch -R AjinOrg/my-app                     # main: build → ECR → "Dev deployment PR opened"
gh pr list -R AjinOrg/aws-platform --state all --limit 2   # deploy(dev): … merged by ajinorg-deployer[bot]
curl -s http://$ALB/dev                            # new version
```
Show: the PR checks, the bot's PR merging itself, `verify.yaml` ✅, the new version on `/dev` while staging and
production still run the old one.

## 2. Release to staging and production
```bash
cd ~/workspace/Task/aws-platform && bash scripts/release.sh   # staging → pick the tag → type "staging"
curl -s http://$ALB/staging
bash scripts/release.sh                                       # production → pick → type "production"
gh pr review <n> -R AjinOrg/aws-platform --approve && gh pr merge <n> -R AjinOrg/aws-platform --squash
curl -s http://$ALB/production
```
Show: the tag list (only tags that ran in the previous environment), the production PR waiting for approval.
Also: Actions → release → Run workflow with tag `abcdef1` → refused ("never ran in dev").

## 3. Infrastructure change with approval
PR changing `terraform/` (in this build: ECR `keep_images = 25`, then back to 30).
Show: the plan as a PR comment (`Plan: 0 to add, 1 to change`), the downloadable `tfplan.txt`, after merge the
**Waiting** apply job → **Review deployments** → approve → apply log; result:
`aws ecr get-lifecycle-policy --repository-name my-app`.

## 4. Blocked in the cluster (Kyverno)
```bash
cd ~/workspace/Task/aws-platform
for f in demo/bad-privileged.yaml demo/bad-root.yaml demo/bad-registry.yaml demo/bad-no-limits.yaml; do
  echo "== $f"; kubectl apply -f "$f"; done
kubectl run sneaky -n dev --image=nginx                      # bare pod: rejected too
```
Expected: each rejected by exactly its policy (`disallow-privileged-containers`, `require-run-as-non-root`,
`restrict-image-registries`, `require-requests-limits`). For privileged/root, Pod Security only *warns* and Kyverno
*blocks*: two layers. Outside the app namespaces nothing is blocked (`kubectl run x -n default --image=nginx` works).

## 5. Blocked: scale to zero
```bash
kubectl scale deploy my-app -n dev --replicas=0      # rejected by require-min-replicas
kubectl apply -f demo/bad-zero-replicas.yaml         # rejected
```
Needs branch `policy/require-min-replicas` merged first; until then scaling to 0 works (used in the client demo).
Why it matters: replicas are owned by the HPA (not in Git), so ArgoCD would not restore them and the HPA does not
scale up from 0 ([decision 23](decisions.md#23-replicas-owned-by-the-hpa-scale-to-zero-blocked-by-kyverno)).

## 6. Blocked in CI: Docker Hub image in values
```bash
git checkout -b test/kyverno-ci-block
sed -i '/^image:$/a\  repository: docker.io/library/nginx' gitops/apps/my-app/values-dev.yaml
git commit -am "test: Docker Hub image" && git push -u origin test/kyverno-ci-block && gh pr create --fill
gh pr checks --watch     # "Helm lint + kubeconform + Kyverno" ✗ restrict-image-registries → merge blocked
gh pr close test/kyverno-ci-block --delete-branch
```

## 7. Blocked in CI: vulnerable image
Happened for real in this build: Trivy blocked `distroless/nodejs22-debian12` (1 critical + 5 high OpenSSL CVEs);
fixed by moving to `debian13`. To replay: change the Dockerfile's runtime image to an old base in a PR → the image
job fails at "Trivy image scan".

## 8. Blocked in CI: secret in code
```bash
git checkout -b demo/secret
echo "aws_secret_access_key = $(head -c 30 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)" >> config.example
git add config.example && git commit -m "demo: hardcoded secret" && git push -u origin demo/secret && gh pr create --fill
```
Expected: "Secrets scan (Gitleaks)" fails, naming file and line; merge blocked. Close the PR and delete the branch
(the commit stays only on that branch).

## 9. Blocked in CI: insecure infrastructure
PR in `aws-platform` adding a security group rule `0.0.0.0/0` on port 22 (any Terraform file). Expected: "IaC
security scan (Checkov)" fails; the plan is never applied. Close the PR.

## 10. GitOps self-heal
```bash
kubectl scale deploy aws-load-balancer-controller -n kube-system --replicas=0   # in Git: 2
kubectl get deploy aws-load-balancer-controller -n kube-system -w             # back to 2/2 within seconds
kubectl delete clusterpolicy require-probes; sleep 75; kubectl get clusterpolicy require-probes   # restored
```

## 11. Monitoring and alerting
Grafana (port-forward, [runbook](runbook.md#access)) → Dashboards → **my-app**: replicas, HPA, CPU, memory,
restarts, Karpenter capacity, logs. Explore → Loki → `{namespace="dev"}`. Alerting → Alert rules → `MyApp`.
`Watchdog` is always firing on purpose (proves the alert pipeline works).

## 12. Autoscaling under load 🔜
Being built (POC item 4): a compliant load generator (`demo/load-test.yaml`, image from ECR); watch in Grafana
(my-app dashboard): CPU above 70 % → HPA adds pods → pending pods → Karpenter adds a Spot node → load stops → pods and
node removed.
