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
| 6 | Blocked in CI: Docker Hub image in values | Kyverno CLI in platform-ci | ✅ (draft PR `DEMO: CI must fail`) |
| 7 | Blocked in CI: vulnerable image | Trivy | ✅ (real OpenSSL CVEs) |
| 8 | Blocked in CI: secret in code | Gitleaks | ✅ (draft PRs in both repos) |
| 9 | Blocked in CI: insecure infrastructure | Checkov | ✅ (draft PR `DEMO: CI must fail`) |
| 10 | GitOps self-heal | ArgoCD restores drift | ✅ |
| 11 | Monitoring and alerting | Dashboard, logs, `MyAppDown` | ✅ |
| 12 | Autoscaling under load | HPA + Karpenter, watched in Grafana | ✅ |
| 13 | All CI gates fail in one PR (both repos) | Every check red; image build skipped | ✅ (kept as draft PRs) |

Running order, timing and talking points for a client: [client-review.md](client-review.md).

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
gh pr list -R AjinOrg/helm-chart --state all --limit 2     # deploy(dev): … merged by ajinorg-deployer[bot]
curl -s http://$ALB/dev/my-app                     # new version
```
Show: the PR checks, the bot's PR merging itself, `verify.yaml` ✅, the new version on `/dev/my-app` while staging
and production still run the old one.

## 2. Release to staging and production
```bash
cd ~/workspace/Task/helm-chart && bash scripts/release.sh     # my-app → staging → pick the tag → type "staging"
curl -s http://$ALB/staging/my-app
bash scripts/release.sh                                       # my-app → production → pick → type "production"
gh pr review <n> -R AjinOrg/helm-chart --approve && gh pr merge <n> -R AjinOrg/helm-chart --squash
curl -s http://$ALB/production/my-app
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
Values live in AjinOrg/helm-chart; its CI applies the platform's Kyverno policies.
```bash
cd ~/workspace/Task/helm-chart && git checkout main && git pull && git checkout -b test/kyverno-ci-block
sed -i '/^image:$/a\  repository: docker.io/library/nginx' apps/my-app/values-dev.yaml
git commit -am "test: Docker Hub image" && git push -u origin test/kyverno-ci-block && gh pr create --fill
gh pr checks --watch     # "Render + kubeconform + Kyverno" ✗ restrict-image-registries → merge blocked
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

## 12. Autoscaling under load
```bash
kubectl get hpa my-app -n dev -w          # terminal 1
kubectl get nodeclaims -w                 # terminal 2
kubectl apply -f demo/load-test.yaml      # terminal 3: 3 generator pods for 10 min
kubectl logs -n dev -l app.kubernetes.io/name=load-test -f --max-log-requests 3
kubectl delete -f demo/load-test.yaml     # afterwards (also removes its 2 NetworkPolicies)
```
Show in Grafana (my-app dashboard): CPU above 70 % → HPA adds pods (dev: max 10, 200m each) → pods Pending →
Karpenter adds a Spot node → load stops → pods back to the minimum after ~5 min → empty node removed after ~5 more.
The generator is compliant (the my-app image from ECR running a script; Kyverno and Pod Security apply) and opens
generator → my-app:8080 only for the test (dev is default-deny).

## 13. All CI gates fail in one PR
Draft PRs `DEMO: CI must fail (do not merge)` on branch `demo/ci-failures` in both repos, kept for demos.
Re-run live with a dummy commit (my-app: append `// demo run` to `src/payment-config.js` instead):
```bash
git checkout demo/ci-failures && echo "# demo run $(date +%F-%H%M)" >> demo/ci-failure/payment.env
git commit -am "DEMO: change while presenting" && git push && git checkout main
```

| Repo | Planted | Fails |
|---|---|---|
| aws-platform | `demo/ci-failure/payment.env` (fake API key) | Gitleaks |
| aws-platform | `docker.io/library/nginx` in `values-dev.yaml` | Kyverno (`restrict-image-registries`). Since the move to helm-chart this file no longer exists on main: replay this row in helm-chart (scenario 6) |
| aws-platform | `terraform/environments/dev/ci-failure-demo.tf`: SSH from 0.0.0.0/0, unformatted | Checkov (`CKV_AWS_24`), Terraform fmt (also the terraform workflow) |
| my-app | `src/payment-config.js` (fake API key) | Gitleaks |
| my-app | `test/demo-failure.test.js` (expects 201 from `/healthz`) | Unit tests |
| my-app | `lodash@4.17.15` | npm audit, Trivy fs |
| my-app | `USER root` in the Dockerfile | Trivy fs (misconfiguration) |
| my-app | – | Build image + Trivy image + Kyverno **skipped**: nothing reaches ECR |

Never merge these PRs: the fake secrets would enter main's history and Gitleaks would fail on main. Close without
deleting the branch (`gh pr close <n>`) and `gh pr reopen <n>` for the next demo.
