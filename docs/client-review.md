# Client Review: Run Sheet

A 60-minute walkthrough of the POC with live demos, in an order that hides the waiting: the slow pipelines are
started first and their results shown later. Commands and expected results for each scenario are in
[demo-scenarios.md](demo-scenarios.md); this page is the order, the timing and what to say.

## The day before
- Rehearse once end to end; note how long the my-app pipeline (PR → deployed) and platform-ci take.
- Both `DEMO: CI must fail (do not merge)` draft PRs (aws-platform and my-app) are open and red.
- Branch `policy/require-min-replicas` stays **unmerged** (scale-down is shown live in part 6).

## 60 minutes before
```bash
cd ~/workspace/Task/aws-platform && git checkout main && git pull
bash scripts/platform-status.sh            # STOPPED → start it (~25–30 min)
bash scripts/platform-start.sh             # then: secret values, re-run the my-app pipeline, new passwords (script prints how)
```

## 15 minutes before
```bash
kubectl get applications -n argocd                    # all Synced / Healthy
kubectl get pods -A | grep -vE "Running|Completed"    # nothing listed
kubectl get pods -n dev                               # my-app 1/1
ALB=$(kubectl get ingress my-app -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$ALB/dev/my-app | jq                   # note "version"
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80 &
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager -n monitoring 9093:9093 &
```
Browser tabs, logged in: ArgoCD (`my-app-dev`) · Grafana (my-app dashboard) · Alertmanager · GitHub PRs and Actions
of both repos · [architecture.md](architecture.md). Terminal: `kubectl get pods -n dev -w`.

---

## Agenda

| # | Time | Part | Live |
|---|---|---|---|
| 1 | 0–5 | Goal and architecture | – |
| 2 | 5–10 | Start the pipelines (good and bad changes, both repos) | ✅ |
| 3 | 10–20 | Infrastructure as code and GitOps | ✅ |
| 4 | 20–30 | Security gates: the red PRs | ✅ |
| 5 | 30–35 | Guardrails in the cluster (Kyverno) | ✅ |
| 6 | 35–40 | Observability: scale to zero → alert | ✅ |
| 7 | 40–50 | Autoscaling under load | ✅ |
| 8 | 50–53 | Application delivered: result of part 2 | ✅ |
| 9 | 53–60 | Cost, trade-offs, next steps, questions | – |

### 1. Goal and architecture (5 min)
Open [architecture.md](architecture.md). Three layers, three owners: AWS infrastructure and platform add-ons
(`aws-platform`, infra team), how services run (`helm-chart`: one shared chart + values per service, release team),
the services themselves (`my-app`, developers). One EKS cluster, `dev` / `staging` / `production` namespaces,
Spot nodes from Karpenter. Mumbai region (`ap-south-1`).
> "Everything you will see is defined in Git. Nobody changes the cluster by hand."

### 2. Start the pipelines (5 min)
Start the slow ones now; their results are shown in parts 4 and 8.
```bash
# bad changes: new CI run on both draft PRs
cd ~/workspace/Task/aws-platform && git checkout demo/ci-failures
echo "# demo run $(date +%F-%H%M)" >> demo/ci-failure/payment.env && git commit -am "DEMO: change while presenting" && git push && git checkout main
cd ~/workspace/Task/my-app && git checkout demo/ci-failures
echo "// demo run $(date +%F-%H%M)" >> src/payment-config.js && git commit -am "DEMO: change while presenting" && git push && git checkout main

# good change in the app: code + test
git checkout main && git pull && git checkout -b test/live-demo
sed -i "s/    app: 'my-app',/    app: 'my-app',\n    message: 'Hello from the live demo',/" src/app.js
sed -i "s/  assert.equal(body.app, 'my-app');/  assert.equal(body.app, 'my-app');\n  assert.equal(body.message, 'Hello from the live demo');/" test/app.test.js
git diff && git commit -am "Add a greeting message to the response" && git push -u origin test/live-demo && gh pr create --fill
```
> "Two developers push at the same time: one with a clean change, one with four classic mistakes."

### 3. Infrastructure as code and GitOps (10 min)
- **Terraform:** `terraform/` modules (VPC, EKS, ECR, IAM, secrets). Show a merged infrastructure PR with its
  plan comment and the approval gate ([scenario 3](demo-scenarios.md#3-infrastructure-change-with-approval)).
- **Release-team good change, live** (values are in helm-chart):
  ```bash
  cd ~/workspace/Task/helm-chart && git checkout main && git pull && git checkout -b test/live-demo
  sed -i 's/^  minReplicas: 1$/  minReplicas: 2/' apps/my-app/values-dev.yaml
  git commit -am "dev: run at least 2 replicas" && git push -u origin test/live-demo
  gh pr create --fill && gh pr checks --watch && gh pr merge --squash --delete-branch
  ```
  ArgoCD: `my-app-dev` OutOfSync → Synced; the terminal shows a 2nd pod.
- **Self-heal:** `kubectl scale deploy aws-load-balancer-controller -n kube-system --replicas=0` → back to 2 in
  seconds ([scenario 10](demo-scenarios.md#10-gitops-self-heal)).
> "A change is a pull request. The cluster pulls it in, and puts back anything changed by hand."

Meanwhile: merge the my-app PR from part 2 once green (`gh pr merge test/live-demo -R AjinOrg/my-app --squash --delete-branch`).

### 4. Security gates: the red PRs (10 min)
Open both `DEMO: CI must fail` PRs; show the failed job, the log line, the disabled **Merge** button.

| Repo | Check | Catches |
|---|---|---|
| aws-platform | Gitleaks | API key in `demo/ci-failure/payment.env` |
| helm-chart | Kyverno (CLI) | Docker Hub image in dev values (`restrict-image-registries`); [scenario 6](demo-scenarios.md#6-blocked-in-ci-docker-hub-image-in-values) |
| aws-platform | Checkov | SSH open to `0.0.0.0/0` (`CKV_AWS_24`) |
| aws-platform | Terraform fmt | Unformatted Terraform |
| my-app | Gitleaks | API key in `src/payment-config.js` |
| my-app | Unit tests | Broken behaviour |
| my-app | npm audit + Trivy fs | lodash 4.17.15 (high CVEs), `USER root` |
| my-app | Build + Trivy image + Kyverno | **Skipped**: nothing built, nothing in ECR |

Also mention: Trivy blocked a real vulnerable base image during the build ([scenario 7](demo-scenarios.md#7-blocked-in-ci-vulnerable-image)).
> "Each mistake is stopped before review even starts, and a failed check means no image is ever built."

### 5. Guardrails in the cluster (5 min)
```bash
cd ~/workspace/Task/aws-platform
for f in demo/bad-privileged.yaml demo/bad-root.yaml demo/bad-registry.yaml demo/bad-no-limits.yaml; do
  echo "== $f"; kubectl apply -f "$f"; done
kubectl run sneaky -n dev --image=nginx
```
Each is rejected by its Kyverno policy.
> "Even someone with cluster access cannot run an insecure workload: CI checks it first, the cluster checks it again."

### 6. Observability: scale to zero → alert (5 min)
```bash
kubectl scale deploy my-app -n dev --replicas=0
```
Grafana my-app dashboard: replicas drop to 0. Alertmanager: `MyAppDown` fires within ~2 minutes. Loki:
Explore → `{namespace="dev"}`.
```bash
kubectl scale deploy my-app -n dev --replicas=2    # recover (the HPA takes over)
```
> "The HPA owns the replica count, so GitOps doesn't restore it; the alert catches it. A policy that blocks
> scaling to zero is ready and will be enabled after this review."

### 7. Autoscaling under load (10 min)
```bash
kubectl get hpa my-app -n dev -w        # terminal 1
kubectl get nodeclaims -w               # terminal 2
kubectl apply -f demo/load-test.yaml    # terminal 3
```
Grafana: CPU above 70 % → HPA adds pods → pods Pending → Karpenter adds a Spot node (~1 min) → pods start.
The generator stops after 10 minutes; scale-down (pods after ~5 min, node after ~5 more) is shown in Grafana
history later or described.
> "Pay for capacity only when it's needed: Spot nodes appear in about a minute and disappear when idle."

### 8. Application delivered (3 min)
my-app Actions: build → ECR (OIDC, no stored keys) → `deploy(dev)` PR in helm-chart merged by the bot →
ArgoCD rollout → `verify.yaml` smoke test ✅.
```bash
curl -s http://$ALB/dev/my-app | jq     # "message": "Hello from the live demo", new "version"
```
Staging and production are released on purpose with helm-chart `scripts/release.sh`; production needs approval
([scenario 2](demo-scenarios.md#2-release-to-staging-and-production)).

### 9. Cost, trade-offs, next steps (7 min)
- **Cost:** Dev is destroyed and rebuilt on demand (`platform-stop.sh` / `platform-start.sh`); Spot nodes;
  one shared ALB; no interface VPC endpoints in Dev.
- **Trade-offs and limitations:** [trade-offs.md](trade-offs.md) (shared secret store, no HTTPS/domain yet,
  single region).
- **Next phase after acceptance:** README §11 "Production-grade phase": per-environment secret stores, HTTPS,
  SSO, dedicated staging/production clusters, Kyverno high availability, Alertmanager receivers, SonarQube.
- Questions.

---

## After the review
```bash
kubectl delete -f ~/workspace/Task/aws-platform/demo/load-test.yaml
# dev back to 1 minimum replica
cd ~/workspace/Task/helm-chart && git checkout main && git pull && git checkout -b test/live-demo-revert
sed -i 's/^  minReplicas: 2$/  minReplicas: 1/' apps/my-app/values-dev.yaml
git commit -am "dev: back to 1 minimum replica" && git push -u origin test/live-demo-revert
gh pr create --fill && gh pr checks --watch && gh pr merge --squash --delete-branch
cd ~/workspace/Task/aws-platform && bash scripts/platform-stop.sh   # stop spending
```
Keep both `DEMO` draft PRs open for the next demo. If accepted: merge `policy/require-min-replicas` (open its PR;
the docs' "ready on a branch" wording is changed to "active" in the same PR).

## If something goes wrong
| Problem | Fallback |
|---|---|
| A pipeline is slow | Continue with the next part; come back to it |
| Deployment PR does not appear | Show the last `deploy(dev)` PR (`gh pr list -R AjinOrg/aws-platform --state merged --limit 3`) |
| Karpenter adds no node | Existing nodes had room: show HPA scaling only, explain Karpenter with `kubectl get nodeclaims` |
| Port-forward dropped | Re-run the `kubectl port-forward` line |
| ALB not answering after a start | Wait for the ALB (2–3 min after the Ingress); `kubectl get ingress -n dev` |
