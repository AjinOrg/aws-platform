# gitops

Everything ArgoCD installs in the cluster. ArgoCD watches this folder on the `main` branch of
`AjinOrg/aws-platform`; a merged change is applied to the cluster within about 3 minutes.

```
gitops/
├── bootstrap/                 applied by hand, once
│   ├── argocd-values.yaml     Helm values for installing ArgoCD itself
│   └── root-app.yaml          app-of-apps: "install every Application in platform/ and apps/"
├── platform/                  cluster add-ons (one Application file each)
│   ├── projects.yaml          AppProject "platform": allowed sources for add-ons
│   ├── repositories.yaml      OCI chart registries (Karpenter, External Secrets)
│   ├── aws-load-balancer-controller.yaml
│   ├── karpenter.yaml / karpenter-nodes.yaml
│   ├── external-secrets.yaml / external-secrets-store.yaml
│   └── app-namespaces.yaml
├── platform-config/           plain manifests used by the Applications above (not read by root directly)
│   ├── karpenter/             EC2NodeClass + NodePool
│   ├── external-secrets/      ClusterSecretStore
│   └── namespaces/            dev, staging, production + default-deny network policies
└── apps/                      the application (Day 5)
    ├── my-app.yaml            Application(s) for dev / staging / production
    └── my-app/values-*.yaml   per-environment values; the image tag is updated by the app pipeline
```

| Rule | Why |
|---|---|
| Only `bootstrap/` is applied by hand | Everything else comes from Git, so the cluster can be rebuilt from this folder |
| Chart versions are pinned (`targetRevision`) | An upgrade is a reviewed one-line change, never a surprise |
| `prune` + `selfHeal` on every Application | Git is the only source of truth: manual edits in the cluster are reverted |
| Add-ons run on `node-role: system` nodes | They must not move with Spot interruptions on application nodes |
