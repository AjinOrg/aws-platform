# Documentation

As-built documentation of the AWS platform POC. The original design (proposal v1.6, diagrams) is in
`aws-platform-docs/` outside this repository; these documents describe what was actually built, and mark where it
differs from the design.

| Document | For | Contents |
|---|---|---|
| [architecture.md](architecture.md) | Everyone | Three layers, request flow, network, cluster, delivery flow, security, identities, monitoring, environments, versions |
| [decisions.md](decisions.md) | Reviewers, architects | The 13 design decisions (updated) + 14 decisions made during the build, each with why and the alternative |
| [trade-offs.md](trade-offs.md) | Reviewers, decision makers | Assumptions, design and POC trade-offs, known limitations, future improvements |
| [runbook.md](runbook.md) | Operators | Start/stop, daily checks, access, releases and rollback, infrastructure, secrets, scaling, troubleshooting, emergencies |
| [demo-scenarios.md](demo-scenarios.md) | Presenters | 12 scenarios with commands and expected results; which are already shown |
| [karpenter-and-external-secrets.md](karpenter-and-external-secrets.md) | Engineers | How Karpenter and External Secrets work here; choosing how pods get secrets |

The step-by-step build log (every command, check and result) is the repository [README](../README.md).
