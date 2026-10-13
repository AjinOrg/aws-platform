# aws-platform

The **infrastructure (platform) repository** for the Secure Production-Ready AWS Platform
(design: `aws-platform-docs/output/AWS_Platform_Proposal_v1.6.docx`).

It holds everything needed to build and run the platform: AWS infrastructure, Kubernetes add-ons,
deployment settings, security rules and monitoring. The application code lives in a separate
repository, **`my-app`**.

## Table of Contents
1. [What Will Live Here](#1-what-will-live-here)
2. [Project Settings](#2-project-settings)
3. [Before You Start](#3-before-you-start)
4. [Why Install Tools on Your Own Computer](#4-why-install-tools-on-your-own-computer)
5. [Step 1: Install the Tools](#5-step-1-install-the-tools)
6. [Step 2: Connect to AWS](#6-step-2-connect-to-aws)
7. [Step 3: Connect to GitHub](#7-step-3-connect-to-github)
8. [Step 4: Bootstrap the Terraform State and Pipeline Access](#8-step-4-bootstrap-the-terraform-state-and-pipeline-access)
9. [Step 5: Build the Dev Network (VPC)](#9-step-5-build-the-dev-network-vpc)
10. [Step 6: EKS Cluster, ECR, Secrets and IRSA (Day 2)](#10-step-6-eks-cluster-ecr-secrets-and-irsa-day-2)
    - [Step 7: ArgoCD, App-of-Apps and the Load Balancer Controller (Day 3)](#10b-step-7-argocd-app-of-apps-and-the-load-balancer-controller-day-3)
    - [Step 8: Platform Add-ons (Day 4)](#10c-step-8-platform-add-ons-day-4)
    - [Step 9: The Application (Day 5)](#10d-step-9-the-application-day-5)
    - [Step 10: CI Pipelines (Day 6)](#10e-step-10-ci-pipelines-day-6)
    - [Step 11: Continuous Delivery](#10f-step-11-continuous-delivery-dev--staging--production)
    - [Step 12: Kyverno in the Cluster](#10g-step-12-kyverno-in-the-cluster-policy-enforcement-at-admission)
    - [Step 13: Terraform Pipeline](#10h-step-13-terraform-pipeline-infrastructure-through-pull-requests)
11. [Build Progress (Days 1 to 6)](#11-build-progress-days-1-to-6)
12. [Troubleshooting](#12-troubleshooting)
13. [Cost and Clean-up](#13-cost-and-clean-up)

---

## 1. What Will Live Here

Folders are added step by step as the build progresses.

| Folder | What it holds | Added on |
|---|---|---|
| `scripts/` | Helper scripts: tool installer; Dev stop/start/status (POC cost saving) | Days 1, 4 |
| `bootstrap/` | One-time CloudFormation template: Terraform state bucket, KMS key, GitHub login trust and pipeline roles | Day 1 |
| `terraform/modules/` | Reusable building blocks: `vpc`, `eks`, `ecr`, `iam`, `secrets` | Days 1–2 |
| `terraform/environments/` | Settings for each environment: `dev`, `staging`, `production` | Days 1–3 |
| `gitops/` | What ArgoCD installs: platform add-ons and the app's settings per environment | Days 3–5 |
| `helm/my-app/` | How the application is packaged for Kubernetes | Day 5 |
| `policies/kyverno/` | Security rules: checked in CI and enforced in the cluster (Kyverno) | Day 6, Step 12 |
| `monitoring/` | Alert rules and dashboards | Day 9 |
| `demo/` | Deliberately bad files (must be rejected), later the load test | Days 6, 8 |
| `.github/workflows/` | Pipelines: platform checks, release/verify, Terraform | Day 6, Steps 11, 13 |
| `docs/` | How-it-works guides (now: Karpenter and External Secrets); later architecture, decisions, runbook | Days 4, 10 |

### Terraform modules: ours and community

Every folder in `terraform/modules/` is **our own module**: the environments only ever call these
(`source = "../../modules/<name>"`). Inside, a module either builds resources directly or wraps a widely
used community module from [terraform-aws-modules](https://github.com/terraform-aws-modules), adding only
our decisions.

| Our module | Built with | Community module used | Our decisions inside |
|---|---|---|---|
| `vpc` | Wraps community modules | `terraform-aws-modules/vpc/aws` and its sub-module `//modules/vpc-endpoints` | CIDR layout, NAT per environment, subnet tags, endpoints, flow logs, locked default security group |
| `eks` | Wraps a community module | `terraform-aws-modules/eks/aws` (which itself uses `terraform-aws-modules/kms/aws` for the secrets key) | Endpoint access, access entries, add-on settings (prefix delegation, network policy), system node group, encrypted disks, SSM |
| `iam` | Wraps a community sub-module | `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts` (three times) | Which service account gets which role and which permissions |
| `ecr` | Own resources only | – | `aws_ecr_repository`, `aws_ecr_lifecycle_policy` |
| `secrets` | Own resources only | – | `aws_kms_key`, `aws_kms_alias`, `aws_secretsmanager_secret` |

**Why wrap instead of writing everything ourselves:** the VPC and EKS modules each replace dozens of resources
(route tables, NAT, launch templates, OIDC provider, add-ons) that are easy to get subtly wrong. They are
maintained by the community and used in thousands of setups. Our wrapper keeps the environment code short and
holds the settings that make it *our* platform. ECR and Secrets Manager are small, so they are written directly.

> `terraform-aws-modules` is a community project, not published by AWS or HashiCorp. It is the most widely
> used set of AWS modules on the Terraform Registry.

**Reading a `source` line**

| `source` | Meaning |
|---|---|
| `"../../modules/vpc"` | A local folder in this repository |
| `"terraform-aws-modules/vpc/aws"` | Terraform Registry: `<namespace>/<name>/<provider>`, the module at the root of that repository |
| `"terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"` | The same registry package, but the **sub-folder** after `//`. The IAM package holds many small modules (users, groups, policies, IRSA roles); `//` picks one |

`version = "~> 6.0"` means "6.x, never 7.0", so a breaking major release is never picked up silently.
`terraform init` prints the exact versions chosen (for example eks 21.29.0, iam 6.8.2, vpc 6.7.3).

---

## 2. Project Settings

The values used by this build. None of them are secrets.

| Setting | Value | Note |
|---|---|---|
| AWS account | `471112815218` | |
| AWS region | `ap-south-1` (Mumbai) | The design document uses `us-east-1` as an example; this build uses Mumbai |
| Local AWS profile | `task` | IAM user access keys, temporary for the local build (see [Step 2](#6-step-2-connect-to-aws)) |
| GitHub owner | `AjinOrg` (organization, id `339973007`, created under the personal account `AjinUrolime`); repository ids: `aws-platform` `1411566444`, `my-app` `1411604810` (used in the OIDC trust, see Step 4) | Repositories: `AjinOrg/aws-platform`, `AjinOrg/my-app` |
| Bootstrap stack | `aws-platform-bootstrap` | Termination protection on |
| Terraform state bucket | `aws-platform-tfstate-471112815218` | State path per environment: `aws-platform/<env>/terraform.tfstate` |
| State KMS key | `alias/aws-platform-tfstate` | |
| Dev VPC CIDR | `10.0.0.0/16` | Staging `10.1.0.0/16`, Production `10.2.0.0/16` |
| Dev cluster name | `platform-dev` | Kubernetes 1.36; API reachable only from `103.141.54.90/32` |
| ArgoCD | Chart 10.10.1 (v3.5.4), namespace `argocd` | UI: `kubectl port-forward svc/argocd-server -n argocd 8080:443` → https://localhost:8080 |
| GitOps source | `AjinOrg/aws-platform`, branch `main`, folder `gitops/` | ArgoCD watches only this repository |
| WSL user | `root` (tools and credentials are under `/root`) | Works; a normal user is better practice and can be switched to later |

Set these in every new terminal (or add them to `~/.bashrc`):
```bash
export AWS_PROFILE=task
export AWS_REGION=ap-south-1
```

---

## 3. Before You Start

Have these ready:

| # | What | Why |
|---|---|---|
| 1 | **AWS account** with administrator access (IAM Identity Center user, or a temporary IAM user) | Needed to create the first resources (bootstrap) |
| 2 | **GitHub account** | The two repositories live there; pipelines run in GitHub Actions |
| 3 | **A domain in Route53** (optional on Day 1) | For the HTTPS address of the app on Day 3. Without one, the app is reached on the load balancer's own address over HTTP |
| 4 | **Budget OK** | Dev costs roughly **$8–11 per day** while running (EKS, NAT, endpoints, nodes). See [Cost and Clean-up](#13-cost-and-clean-up) |

---

## 4. Why Install Tools on Your Own Computer

In this design, the **pipelines do most of the work**: GitHub Actions runs Terraform, the scans and the image
builds, and ArgoCD deploys. Local tools are still needed to:

1. **Get started:** the pipelines don't exist yet, so the bootstrap and the first Dev build run from your computer.
2. **Write and test code** before pushing, instead of waiting for the pipeline to find a typo.
3. **Connect to the cluster** to check things and fix problems.
4. **Run the demo** live.

| Tool | Why you need it locally | First used | Needed? |
|---|---|---|---|
| **AWS CLI** | Log in to AWS, deploy the bootstrap, connect kubectl to EKS | Day 1 | Required |
| **Terraform** | Write the infrastructure code, check it, run the first Dev build | Day 1 | Required |
| **kubectl** | Talk to the cluster; run the demo's rejected-pod tests | Day 3 | Required |
| **GitHub CLI (`gh`)** | Create repositories, set protection rules, watch pipeline runs | Day 1 | Recommended (web UI also works) |
| **Helm** | Check the app package renders correctly (ArgoCD does the real deploy) | Day 5 | Recommended |
| **ArgoCD CLI** | Check deployment status; used in the demo (web UI also works) | Day 3 | Optional |
| **Checkov, Trivy, Gitleaks** | Run the same security scans as the pipeline before pushing; rehearse the "blocked" demo cases | Day 6 | Optional (the pipeline runs them anyway) |
| **Docker** | Build and test the app image locally (the pipeline builds the real one) | Day 5 | Optional |

---

## 5. Step 1: Install the Tools

Run everything in the **WSL Ubuntu terminal**, one block at a time.

### 1a. Preparation
```bash
mkdir -p ~/.local/bin
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
sudo apt-get update && sudo apt-get install -y curl unzip python3-venv
```
This creates a personal folder for the tools and adds it to your PATH. The `sudo` line installs a few helpers.

### 1b. Install the tools with the script
`scripts/install-tools.sh` installs **Terraform, Helm, ArgoCD CLI, GitHub CLI, Trivy, Gitleaks and Checkov**:
- it downloads each tool from its official release page,
- **checks every file against its official checksum** and stops if one does not match,
- installs into `~/.local/bin` (no sudo).

Read it first if you like, then run it:
```bash
cd ~/workspace/Task/aws-platform
less scripts/install-tools.sh      # optional: review (press q to quit)
bash scripts/install-tools.sh
```
It ends by printing the installed versions.

> The script installs the latest release of each tool. Security tools are a common target for
> supply-chain attacks, so for the pipelines we pin exact versions later.

### 1c. AWS CLI and kubectl
The script does not install these two. Both go into your own folders (no sudo):
```bash
# AWS CLI v2
cd /tmp && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
python3 -c 'import zipfile; zipfile.ZipFile("awscliv2.zip").extractall(".")' && chmod +x aws/install aws/dist/aws
./aws/install -i ~/.local/aws-cli -b ~/.local/bin

# kubectl (checked against its official checksum)
V=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/$V/bin/linux/amd64/kubectl"
curl -fsSL "https://dl.k8s.io/release/$V/bin/linux/amd64/kubectl.sha256" -o kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - && install -m 755 kubectl ~/.local/bin/kubectl
```
kubectl must be within one minor version of the EKS cluster (checked on Day 2).

### 1d. Docker (optional, for Day 5)
In **Docker Desktop on Windows**: **Settings → Resources → WSL integration → turn on Ubuntu → Apply & restart**.

### 1e. Check everything
```bash
aws --version
terraform version | head -1        # must be 1.10 or later
kubectl version --client | head -1
helm version --short
argocd version --client --short
gh --version | head -1
checkov --version
trivy --version | head -1
gitleaks version
docker version --format '{{.Server.Version}}'   # only if you set up Docker
```

Installed for this build:

| Tool | Version |
|---|---|
| AWS CLI | 2.37.9 |
| Terraform | 1.16.5 |
| kubectl | 1.37.1 |
| Helm | 4.3.0 |
| ArgoCD CLI | 3.5.4 |
| GitHub CLI | 2.102.0 |
| Docker | 29.8.1 |
| Checkov | 3.3.26 |
| Trivy | 0.75.0 |
| Gitleaks | 8.30.1 |

---

## 6. Step 2: Connect to AWS

### Preferred: IAM Identity Center (SSO)

SSO gives you **temporary credentials** that expire after a few hours. No access keys are stored on your
computer, which is the same principle the platform follows.

**Check first:** in the AWS Console, open **IAM Identity Center** and confirm you have a user with the
**AdministratorAccess** permission set on this account.

```bash
aws configure sso
```

| Prompt | What to enter |
|---|---|
| SSO session name | `platform` |
| SSO start URL | Your portal URL, like `https://d-xxxxxxxxxx.awsapps.com/start` |
| SSO region | The region where Identity Center is enabled |
| SSO registration scopes | Press Enter |
| *(browser opens: log in and click **Allow**)* | |
| Account and role | Your account, **AdministratorAccess** |
| Default client region | `ap-south-1` |
| Default output format | `json` |
| Profile name | `platform-admin` |

Use this profile by default and test it:
```bash
echo 'export AWS_PROFILE=platform-admin' >> ~/.bashrc && source ~/.bashrc
aws sts get-caller-identity        # shows your account ID and the SSO role
```

When the session expires later, run:
```bash
aws sso login
```

### If SSO is not available: temporary IAM user access keys

**This build uses this option:** profile `task`, an IAM user with AdministratorAccess. The key is used only
for the local build and is deleted afterwards.

Access keys are long-lived: if they leak (shell history, a pushed file, a backup), anyone can use them until
they are deleted. If you must use them for the initial local build, keep the exposure small:

| Practice | How |
|---|---|
| Use them only for the bootstrap and first Dev build | From Day 8, the pipelines use GitHub OIDC; no keys are needed |
| Turn on MFA for the IAM user | IAM → Users → *user* → Security credentials → Assign MFA device |
| Keep keys only in `~/.aws/credentials` | Never in the repository, `.env` files, scripts or chat messages. Gitleaks in CI would block a pushed key |
| Use a named profile | `export AWS_PROFILE=<profile>` instead of default credentials |
| Deactivate, then delete the key when done | IAM → Users → *user* → Security credentials → Access keys → Deactivate → Delete; also remove it from `~/.aws/credentials` |
| Check nothing still uses it before deleting | The "Last used" column on the same page |
| Rotate if the work runs longer than planned | Create a new key, switch, delete the old one (do not keep two active keys) |

The preferred options remain **IAM Identity Center (SSO)** or **AWS CloudShell**, which give temporary credentials
and store nothing on the laptop.

Check who you are and what you can do:
```bash
aws sts get-caller-identity
aws iam list-attached-user-policies --user-name <iam-user>   # expect AdministratorAccess
aws iam list-open-id-connect-providers                       # an existing GitHub provider changes Step 4
```

---

## 7. Step 3: Connect to GitHub

### Log in
```bash
gh auth login -s read:org,workflow   # GitHub.com → HTTPS → Yes (authenticate Git) → Login with a web browser
gh auth status
gh api user --jq .login            # the account you are logged in as (AjinUrolime)
gh api user/orgs --jq '.[].login'  # organizations you belong to (AjinOrg)
```
- `read:org` lets `gh` see the organization; `workflow` allows pushing files in `.github/workflows/` (Day 6).
- In the browser, also click **Grant** next to the organization under *Organization access*; otherwise
  `gh repo create AjinOrg/...` fails. (Later: GitHub → Settings → Applications → Authorized OAuth Apps → GitHub CLI.)
- WSL cannot open a browser by itself: `echo 'export BROWSER=explorer.exe' >> ~/.bashrc && source ~/.bashrc`.
- The token is stored in `~/.config/gh/hosts.yml`, outside the project. `gh auth logout` removes it.

The **owner** used in Step 4 is whoever owns the repositories: here the organization `AjinOrg`, not the
personal account that logs in. The AWS roles trust exactly `repo:<owner>/<repo>`, and the match is case-sensitive.

### Git identity
```bash
git config --global user.name  "Ajin Vijayan"
git config --global user.email "<github-noreply-address>"   # GitHub → Settings → Emails; keeps your email private
git config --global init.defaultBranch main
```

### Create the repositories
```bash
cd ~/workspace/Task/aws-platform
git init -b main

# 1. Confirm the ignore rules work (prints the rule that matched; prints nothing if NOT ignored)
git check-ignore -v terraform/environments/dev/.terraform/modules
git check-ignore -v terraform/environments/dev/tfplan

# 2. Stage and review
git add .
git status        # must NOT list .terraform/, tfplan*, *.tfstate; must list .terraform.lock.hcl

# 3. Scan exactly what will be committed
gitleaks git --pre-commit --staged -v      # "no leaks found"

# 4. Commit and create the repository (creates it on GitHub, adds remote "origin", pushes main)
git commit -m "Days 1-2: bootstrap, VPC, EKS, ECR, secrets, IRSA"
gh repo create AjinOrg/aws-platform --public --source=. --remote=origin --push
git remote -v

# 5. The application repository (empty until Day 5)
cd ~/workspace/Task
gh repo create AjinOrg/my-app --public --clone
```

| Point | Explanation |
|---|---|
| One `.gitignore` at the root | A pattern without a leading `/` (like `.terraform/`) matches at any depth, so it covers every environment folder |
| `.terraform.lock.hcl` **is** committed | It pins the exact provider versions and checksums so the pipeline uses the same verified files |
| `gitleaks dir .` vs `gitleaks git --staged` | `dir` scans every file on disk, including ignored downloads in `.terraform/` (their example keys show up as findings). `git --staged` scans only what goes into the commit; that is the check that matters |
| Public repositories | On a free organization, branch protection and Environment reviewers (needed on Days 6 and 8) work only on public repositories. Private needs GitHub Team. No secrets are in the code; the AWS account ID is not a credential |

---

## 8. Step 4: Bootstrap the Terraform State and Pipeline Access

**Why this step exists:** Terraform keeps a record of what it built (the *state*). It needs a bucket for that
before it can run, so the bucket cannot be created by the same Terraform code. A small CloudFormation template,
`bootstrap/state-backend.yaml`, creates it once per AWS account. CloudFormation tracks the stack inside AWS,
so there is no local file to lose.

### Deploy
```bash
cd ~/workspace/Task/aws-platform
export AWS_PROFILE=task AWS_REGION=ap-south-1

# 1. Check the template syntax (creates nothing)
aws cloudformation validate-template --template-body file://bootstrap/state-backend.yaml

# 2. Create the stack
aws cloudformation deploy \
  --template-file bootstrap/state-backend.yaml \
  --stack-name aws-platform-bootstrap \
  --parameter-overrides \
      StateBucketName=aws-platform-tfstate-471112815218 \
      GitHubOrg=AjinOrg \
      GitHubOrgId=339973007 AppRepoId=1411604810 PlatformRepoId=1411566444 \
  --capabilities CAPABILITY_NAMED_IAM

# 3. Protect the stack from accidental deletion
aws cloudformation update-termination-protection \
  --enable-termination-protection --stack-name aws-platform-bootstrap

# 4. Show the outputs
aws cloudformation describe-stacks --stack-name aws-platform-bootstrap \
  --query "Stacks[0].Outputs" --output table
```
- `CAPABILITY_NAMED_IAM`: CloudFormation will not create named IAM roles unless you acknowledge it.
- An AWS account can have only **one** GitHub OIDC provider. If one already exists, add
  `CreateOidcProvider=false` to the parameters.
- If the deploy fails, show the reason:
  ```bash
  aws cloudformation describe-stack-events --stack-name aws-platform-bootstrap \
    --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output table
  ```

### Changing a parameter later (update, not recreate)
Run the same `deploy` command with the new value. CloudFormation compares it with the running stack and
changes only what differs; the bucket, its state files and the KMS key are untouched. Termination protection
blocks deletion only, not updates.

Example: the GitHub owner changed from `AjinTV` to `AjinUrolime`, then the organization `AjinTVUrolime`, and finally `AjinOrg`.
Only the three roles' trust policies change:
```bash
# Preview: create a change set without executing it
aws cloudformation deploy --template-file bootstrap/state-backend.yaml --stack-name aws-platform-bootstrap \
  --parameter-overrides StateBucketName=aws-platform-tfstate-471112815218 GitHubOrg=AjinOrg \
      GitHubOrgId=339973007 AppRepoId=1411604810 PlatformRepoId=1411566444 \
  --capabilities CAPABILITY_NAMED_IAM --no-execute-changeset
# Newest change set (not Summaries[0]: an old FAILED one may still be listed first)
CS=$(aws cloudformation list-change-sets --stack-name aws-platform-bootstrap \
       --query "sort_by(Summaries,&CreationTime)[-1].ChangeSetName" --output text); echo "CS=[$CS]"
aws cloudformation describe-change-set --stack-name aws-platform-bootstrap --change-set-name "$CS" \
  --query "[Status,StatusReason]" --output text          # CREATE_COMPLETE
aws cloudformation describe-change-set --stack-name aws-platform-bootstrap --change-set-name "$CS" \
  --query "Changes[].ResourceChange.[Action,LogicalResourceId,Replacement]" --output table
# expect: Modify EcrPushRole / TerraformPlanRole / TerraformApplyRole, Replacement False

# Apply
aws cloudformation execute-change-set --stack-name aws-platform-bootstrap --change-set-name "$CS"
aws cloudformation wait stack-update-complete --stack-name aws-platform-bootstrap

# Leftovers: a deploy with no differences leaves a FAILED change set ("didn't contain changes"). Remove them:
for cs in $(aws cloudformation list-change-sets --stack-name aws-platform-bootstrap \
             --query "Summaries[?Status=='FAILED'].ChangeSetName" --output text); do
  aws cloudformation delete-change-set --stack-name aws-platform-bootstrap --change-set-name "$cs"
done

# Check
aws iam get-role --role-name aws-platform-ecr-push \
  --query "Role.AssumeRolePolicyDocument.Statement[0].Condition" --output json
```

### What was created

| Output | Value | Purpose | Used by |
|---|---|---|---|
| `StateBucketName` | `aws-platform-tfstate-471112815218` | Holds the Terraform state, one file per environment | `terraform/environments/*/backend.tf` |
| `StateKeyArn` | `arn:aws:kms:ap-south-1:471112815218:key/aeb2d59a-59c0-4880-ab23-0462390a9276` | Encrypts the state bucket | Bucket encryption (automatic) |
| `EcrPushRoleArn` | `arn:aws:iam::471112815218:role/aws-platform-ecr-push` | Push images to the `my-app` ECR repository | `my-app` release pipeline (Day 6) |
| `TerraformPlanRoleArn` | `arn:aws:iam::471112815218:role/aws-platform-terraform-plan` | `terraform plan` on pull requests | Terraform pipeline (Day 8) |
| `TerraformApplyRoleArn` | `arn:aws:iam::471112815218:role/aws-platform-terraform-apply` | `terraform apply` after approval | Terraform pipeline (Day 8) |

The stack also creates the **GitHub OIDC provider** (lets AWS trust GitHub Actions' login tokens) and the
shared policy **`aws-platform-tfstate-access`** (read/write the state files and use the state key).

**Who can use each role.** GitHub Actions presents a signed token saying which repository and branch or
environment the job runs in. AWS gives temporary credentials (1 hour) only if that matches the role's trust
condition. No AWS keys are stored in GitHub.

| Role | Trusted only for (`sub` claim) | Can do |
|---|---|---|
| `aws-platform-ecr-push` | `repo:AjinOrg@339973007/my-app@1411604810:ref:refs/heads/main` | Push and read images in the `my-app` ECR repository; nothing else |
| `aws-platform-terraform-plan` | `repo:AjinOrg@339973007/aws-platform@1411566444:pull_request` and `...:ref:refs/heads/main` | Read-only on the account (`ReadOnlyAccess`) plus the state files; cannot change infrastructure |
| `aws-platform-terraform-apply` | `repo:AjinOrg@339973007/aws-platform@1411566444:environment:terraform-apply` | Administrator; reachable only by a job a reviewer has approved |

The ECR push role is in use since Day 6 (my-app pipeline). The two Terraform roles are used from Day 8: until
then Terraform runs from your computer with your own credentials.

### GitHub's immutable OIDC subject (owner and repository IDs)
The repositories use GitHub's **immutable subject** format: the `sub` claim contains the numeric IDs of the
owner and the repository, not only their names.

| | `sub` claim |
|---|---|
| Classic | `repo:AjinOrg/my-app:ref:refs/heads/main` |
| Immutable (used here) | `repo:AjinOrg@339973007/my-app@1411604810:ref:refs/heads/main` |

**Why it is safer:** names can be reused, IDs cannot. If a repository were deleted and someone recreated one
with the same name, a classic trust policy would accept *their* tokens; with IDs only this exact repository matches.

| ID | Value | Find it with |
|---|---|---|
| Owner `AjinOrg` | `339973007` | `gh api orgs/AjinOrg --jq .id` |
| `my-app` | `1411604810` | `gh api repos/AjinOrg/my-app --jq .id` |
| `aws-platform` | `1411566444` | `gh api repos/AjinOrg/aws-platform --jq .id` |
| Format in use | `use_immutable_subject: true` | `gh api repos/AjinOrg/<repo>/actions/oidc/customization/sub` (`sub_claim_prefix`) |

The template supports both formats: with `GitHubOrgId`, `AppRepoId`, `PlatformRepoId` set it builds the immutable
subject; left empty, the classic one.

**Symptom of a mismatch:** the pipeline fails at "AWS credentials" with
`Not authorized to perform sts:AssumeRoleWithWebIdentity`. Compare the role's condition
(`aws iam get-role --role-name <role> --query Role.AssumeRolePolicyDocument`) with the repository's `sub_claim_prefix`.
This happened in this build: the roles had the classic format, GitHub sent the immutable one; fixed by the
template parameters above.

### Verify the state bucket
```bash
B=aws-platform-tfstate-471112815218
aws s3api get-bucket-versioning --bucket $B          # "Status": "Enabled"
aws s3api get-bucket-encryption --bucket $B          # "SSEAlgorithm": "aws:kms", "BucketKeyEnabled": true
aws s3api get-public-access-block --bucket $B        # all four values true
aws s3api get-bucket-policy --bucket $B --query Policy --output text | python3 -m json.tool   # Deny when aws:SecureTransport is false
aws kms get-key-rotation-status --key-id alias/aws-platform-tfstate                         # "KeyRotationEnabled": true
```

| Check | Why it matters |
|---|---|
| Versioning on | Every state write is kept; a corrupted state can be rolled back. Old versions expire after 90 days |
| KMS encryption | Reading a state file needs both S3 access **and** permission to use the key; every key use is logged in CloudTrail |
| Public access blocked | The bucket can never be made public, even by mistake |
| HTTPS-only policy | Unencrypted (HTTP) requests are refused |
| Key rotation | Key material is rotated automatically every year |
| `DeletionPolicy: Retain` | Bucket and key survive even if the stack is deleted |

### About the KMS key policy
The key policy has one statement: principal `arn:aws:iam::471112815218:root`, action `kms:*`.
- `:root` means **this AWS account**, not the root user. It hands the decision to IAM policies in the account.
  Without it, not even an administrator could manage the key.
- In a key policy, `Resource: "*"` means **this key only**.
- The bucket is not named in the key policy because the link goes the other way: the **bucket's** encryption
  setting points to the key. The key policy only answers *who* may use the key; S3 calls KMS on behalf of
  the person reading or writing, so that person needs permission on both.

---

## 9. Step 5: Build the Dev Network (VPC)

Code: `terraform/modules/vpc/` (reusable) and `terraform/environments/dev/` (Dev values).

```bash
cd ~/workspace/Task/aws-platform/terraform/environments/dev
terraform init                  # downloads the AWS provider and VPC module, connects to the S3 state
terraform plan -out=tfplan      # shows what WILL be created and saves that exact plan
terraform apply tfplan          # creates exactly what the plan showed
```
`apply tfplan` applies exactly what you reviewed; the Day 8 pipeline works the same way.

**Check the plan before applying:** roughly 40 resources to add, 0 to change, 0 to destroy; 1 `aws_nat_gateway`;
3 private and 3 public `aws_subnet`.

| Part | Design | Why |
|---|---|---|
| Private subnets | 3 × `/19` (10.0.0.0/19, 10.0.32.0/19, 10.0.64.0/19) | EKS nodes and pods. Large, because every pod gets a VPC IP address |
| Public subnets | 3 × `/24` (10.0.96.0/24 – 10.0.98.0/24) | Load balancer and NAT only; no workloads |
| NAT Gateway | 1 shared in Dev; 1 per AZ in Staging/Production | Outbound-only internet for private nodes |
| VPC endpoints | S3 (gateway, free); ECR API, ECR DKR, STS, Secrets Manager (interface) | Image pulls, IRSA logins and secret reads stay on the AWS network |
| Subnet tags | `kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`, `karpenter.sh/discovery` | Tell the load balancer controller and Karpenter which subnets to use |
| Hardening | Default security group emptied, no automatic public IPs, VPC flow logs (7 days) | Deny by default; traffic records for troubleshooting and audits |

The module wraps the community module `terraform-aws-modules/vpc`; our module only holds our decisions
(CIDR layout, tags, endpoints, flow logs).

The backend values in `backend.tf` are written directly because Terraform reads the backend before variables.

> In this build, the VPC and Day 2 resources are planned and applied together in one run (Step 6).

---

## 10. Step 6: EKS Cluster, ECR, Secrets and IRSA (Day 2)

Code: `terraform/modules/{eks,ecr,secrets,iam}/`, called from `terraform/environments/dev/main.tf`.

### Fill in two values first
In `terraform/environments/dev/terraform.tfvars`, set these two values (this build: `kubernetes_version = "1.36"`,
`admin_cidrs = ["103.141.54.90/32"]`, the office public IP in Kochi):
```bash
# 1. Kubernetes version: pick the newest with "STANDARD_SUPPORT"
aws eks describe-cluster-versions \
  --query "clusterVersions[].[clusterVersion,versionStatus,defaultVersion]" --output table

# 2. Your public IP (the only address allowed to reach the cluster API from outside)
curl -s https://checkip.amazonaws.com
```
| Setting | Example | Why |
|---|---|---|
| `kubernetes_version` | `"1.36"` | kubectl (1.37) must be within one minor version of the cluster |
| `admin_cidrs` | `["203.0.113.25/32"]` | `/32` = exactly one IP. If your IP changes, kubectl times out: update this value and apply again |

### Plan and apply (VPC + Day 2 together, about 20 minutes)
```bash
cd ~/workspace/Task/aws-platform/terraform/environments/dev
terraform init          # needed again: new modules (eks, iam) were added
terraform plan -out=tfplan
terraform show -no-color tfplan > tfplan.readable.txt   # optional: readable copy for review
terraform apply tfplan
```
- The saved plan is a **binary zip**, whatever its name; apply it with the exact name given to `-out`.
  Name it `tfplan` (not `.txt`) to avoid confusion. Both `tfplan` and `tfplan.*` are git-ignored.
- A saved plan is tied to the moment it was made: after any code, tfvars or state change, `apply` refuses it
  ("Saved plan is stale") and you plan again.

### Plan review (this build)
`Plan: 86 to add, 0 to change, 0 to destroy.` Checked before applying:

| Area | In the plan |
|---|---|
| VPC | `10.0.0.0/16`; private `/19` and public `/24` subnets in ap-south-1a/b/c; `map_public_ip_on_launch = false` |
| NAT / internet | 1 NAT Gateway, 1 Elastic IP, 1 Internet Gateway |
| Endpoints, flow logs | 5 VPC endpoints; 1 flow log with a 7-day log group |
| EKS | `platform-dev`, version 1.36; private endpoint on; public endpoint only `103.141.54.90/32`; secrets encryption |
| Access | `authentication_mode = API`; creator admin off; one access entry (the IAM user) with `AmazonEKSClusterAdminPolicy` |
| Add-ons | vpc-cni (prefix delegation, network policy), kube-proxy, coredns |
| Nodes | On-Demand t3.medium, 2–3 nodes; 30 GB encrypted gp3; IMDSv2 required, hop limit 1 (pods cannot use the node's IAM role); SSM policy |
| ECR, secrets | `my-app` immutable + scan on push; 3 empty secrets with their own KMS key |
| IRSA | `platform-dev-alb-controller`, `-external-secrets`, `-my-app`; cluster OIDC provider |
| Security groups | No inbound rule open to `0.0.0.0/0` (only outbound rules use it) |

Resource count by type: 13 security group rules, 9 role policy attachments, 6 subnets, 6 route table associations,
6 IAM roles, 5 VPC endpoints, 4 IAM policies, 3 security groups, 3 secrets, 3 EKS add-ons, 2 KMS keys (EKS secrets,
app secrets), 2 log groups (EKS, flow logs), plus the VPC, NAT, IGW, EIP, cluster, node group, launch template,
access entry, OIDC provider, ECR repository and lifecycle policy.

### What gets created

| Module | Creates | Security points |
|---|---|---|
| `eks` | EKS cluster `platform-dev`, system managed node group (2 × t3.medium, On-Demand), add-ons (VPC CNI, kube-proxy, CoreDNS), cluster OIDC provider | Private API endpoint for nodes; public endpoint only for `admin_cidrs`. Kubernetes Secrets encrypted with KMS. API, audit and authenticator logs in CloudWatch. Access only through EKS access entries. Encrypted node disks. Node access via SSM Session Manager, no SSH |
| `ecr` | Repository `my-app` | Immutable tags (a scanned image can't be swapped), scan on push, KMS encryption, lifecycle (untagged images deleted after 7 days, newest 30 kept) |
| `secrets` | KMS key `alias/platform-dev-secrets`; secrets `platform-dev/my-app/{dev,staging,production}` | Terraform creates **empty** secrets; values are stored with the CLI, so they never reach Git or the Terraform state |
| `iam` | IRSA roles `platform-dev-alb-controller`, `platform-dev-external-secrets`, `platform-dev-my-app` | Each role trusts exactly one `namespace:serviceaccount` on this cluster. External Secrets may read only the three app secrets and use only their key. The app role starts with no permissions |

**Settings worth understanding**

| Setting | Why |
|---|---|
| VPC CNI `ENABLE_PREFIX_DELEGATION` + `maxPods: 110` | On EKS every pod takes a VPC IP. A t3.medium normally fits only 17 pods; with /28 prefixes it fits up to 110. The platform add-ons alone would need more than 34 pods on two nodes |
| VPC CNI `enableNetworkPolicy` | Without it, Kubernetes NetworkPolicies are accepted but **not enforced**; the default-deny rules of Day 4 depend on it |
| `authentication_mode = "API"` | Access is managed by EKS access entries (visible in the console and in Terraform), not the older `aws-auth` ConfigMap |
| `enable_cluster_creator_admin_permissions = false` | Admins are listed explicitly in `cluster_admin_arns`, instead of "whoever ran Terraform first" |
| System nodes On-Demand | Platform add-ons (ArgoCD, Karpenter, etc.) must not vanish with a Spot interruption; app nodes use Spot via Karpenter (Day 4) |

### After the apply
Result in this build: `Apply complete! Resources: 86 added, 0 changed, 0 destroyed.`, and all checks below passed.

```bash
# Outputs: cluster name/endpoint, ECR URL, secret names, IRSA role ARNs (used on Days 3–4)
terraform output

# Connect kubectl (writes the cluster entry to ~/.kube/config)
aws eks update-kubeconfig --name platform-dev --region ap-south-1
kubectl version | grep -i version    # client 1.37, server 1.36
kubectl get nodes -o wide            # 2 nodes, Ready, internal IPs 10.0.x.x, no external IP
kubectl get pods -A                  # aws-node, kube-proxy, coredns Running

# Check the pod limit from prefix delegation
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.pods}'   # 110 per node

# Check network policy enforcement is installed
kubectl get ds aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[*].name}'   # aws-node aws-eks-nodeagent

# Store the app secret values (example: one key/value pair per namespace)
for ns in dev staging production; do
  aws secretsmanager put-secret-value --secret-id platform-dev/my-app/$ns \
    --secret-string "{\"GREETING\":\"hello from $ns\"}"
done
```
Store real values the same way; never put them in a file in the repository.

**Names created (for later days):**

| Item | Value |
|---|---|
| Cluster | `platform-dev` (Kubernetes 1.36) |
| ECR repository | `471112815218.dkr.ecr.ap-south-1.amazonaws.com/my-app` |
| Secrets | `platform-dev/my-app/dev`, `platform-dev/my-app/staging`, `platform-dev/my-app/production` |
| IRSA: ALB controller | `arn:aws:iam::471112815218:role/platform-dev-alb-controller` (service account `kube-system/aws-load-balancer-controller`) |
| IRSA: External Secrets | `arn:aws:iam::471112815218:role/platform-dev-external-secrets` (service account `external-secrets/external-secrets`) |
| IRSA: application | `arn:aws:iam::471112815218:role/platform-dev-my-app` (service account `my-app` in `dev`, `staging`, `production`) |

**What runs where from now on:** Terraform manages AWS resources and changes rarely. Everything inside the
cluster (add-ons, the application) is deployed by ArgoCD from Git (Day 3 onwards). The next Terraform change is
Karpenter's IAM role and queue on Day 4; from Day 8 Terraform runs only through the pipeline.

| Never share or commit | Why |
|---|---|
| `~/.aws/credentials` | AWS access key |
| `~/.config/gh/hosts.yml` | GitHub token |
| `~/.kube/config` | Cluster connection details (no long-lived secret, but personal) |
| Secret values | Belong only in Secrets Manager |

---

## 10b. Step 7: ArgoCD, App-of-Apps and the Load Balancer Controller (Day 3)

Code: `gitops/` (see [gitops/README.md](gitops/README.md)). No domain is used in this build: the app is reached
on the load balancer's own AWS address over HTTP. HTTPS (ACM certificate + Route53 record) can be added later by
adding two annotations to the Ingress and a DNS record; nothing else changes.

### How it fits together
```
You (once):  helm install ArgoCD  ──▶  kubectl apply root-app.yaml
                                              │
ArgoCD:      reads github.com/AjinOrg/aws-platform, folder gitops/
                ├── platform/projects.yaml                  → AppProject "platform"
                └── platform/aws-load-balancer-controller.yaml → Helm chart into kube-system
                                                              (IRSA role platform-dev-alb-controller)
From now on: a merged commit in gitops/ = a change in the cluster (within ~3 minutes)
```

### Install
```bash
cd ~/workspace/Task/aws-platform
git pull                                    # root-app.yaml points at GitHub: the gitops/ files must be pushed first

# 1. ArgoCD (the only Helm install done by hand), from the chart's OCI registry on ghcr.io
helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd -n argocd --create-namespace \
  --version 10.10.1 -f gitops/bootstrap/argocd-values.yaml --wait --timeout 10m
kubectl get pods -n argocd                  # all Running, on the system nodes

# 2. The app-of-apps entry point
kubectl apply -f gitops/bootstrap/root-app.yaml
kubectl get applications -n argocd          # root, aws-load-balancer-controller → Synced / Healthy
```

### Open the ArgoCD UI (not exposed to the internet)
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443      # keep this terminal open
# second terminal:
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```
Open https://localhost:8080 (accept the self-signed certificate warning), user `admin`. Then change the password
and remove the initial one:
```bash
argocd login localhost:8080 --username admin --insecure
argocd account update-password
kubectl delete secret argocd-initial-admin-secret -n argocd
```

### Optional: ArgoCD UI on a URL (VPN), prepared but disabled
This build uses port-forward only. `gitops/bootstrap/argocd-values.yaml` holds a **commented** Ingress block for
later, with two options:

| Option | When | Load balancer |
|---|---|---|
| A | VPN into the VPC (AWS Client VPN or site-to-site) | `scheme: internal`, private IPs only, not on the internet |
| B | Office VPN with a fixed public IP | `scheme: internet-facing` + `inbound-cidrs: <vpn-ip>/32` |

To enable: uncomment `global.domain: ""` and the `server.ingress` block, choose A or B, run `helm upgrade` with the
same values file, and read the URL from `kubectl get ingress -n argocd`. Notes:
- `global.domain: ""` removes the host rule; otherwise the chart's default host `argocd.example.com` makes the
  ALB answer 404 on its own DNS name.
- Without a domain the listener is HTTP, so the password crosses the network unencrypted between browser and ALB:
  acceptable only with option A (the VPN encrypts it). Option B needs an ACM certificate first (lines included,
  commented).
- No Terraform or IAM change is needed: the controller's IRSA role and the subnet tags already cover it.

### Verification (all passed in this build)

**Installed state:** Helm release `argocd` (revision 1, `deployed`, chart `argo-cd-10.10.1`, ArgoCD `v3.5.4`).
Five pods Running across both system nodes: `argocd-application-controller-0`, `argocd-server`,
`argocd-repo-server`, `argocd-applicationset-controller`, `argocd-redis` (no Dex, no notifications).

| # | Test | Command | Expected (✅ seen) |
|---|---|---|---|
| 1 | ArgoCD picked up Git | `kubectl get applications -n argocd`<br>`kubectl get appproject -n argocd` | `root` and `aws-load-balancer-controller` Synced / Healthy; projects `default`, `platform` |
| 2 | Controller running | `kubectl get deploy aws-load-balancer-controller -n kube-system`<br>`kubectl get ingressclass` | `2/2`; pods on system nodes; ingress class `alb` |
| 3 | IRSA works | see block below | Role ARN `platform-dev-alb-controller`; env `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`; no `AccessDenied` in logs |
| 4 | UI + admin password | port-forward, log in, `argocd account update-password`, delete initial secret | UI at https://localhost:8080 shows both apps; password changed; `argocd app list` works |
| 5 | Self-heal | `kubectl scale deploy aws-load-balancer-controller -n kube-system --replicas=0` | Back to `2/2` within seconds: Git says 2 |
| 6 | GitOps loop | change the memory limit in Git, push, `argocd app get aws-load-balancer-controller --refresh` | Limit changed in the cluster with no kubectl/helm (kept at **300Mi**) |

```bash
# Test 3: IRSA
kubectl get sa aws-load-balancer-controller -n kube-system \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo
kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}'; echo
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=30 | grep -iE "error|denied|vpc" || echo "no errors"
```

**What the tests prove**

| Test | Proves |
|---|---|
| 1, 2 | App-of-apps works: one manually applied file led ArgoCD to install everything else from GitHub |
| 3 | The controller calls AWS with its own short-lived IRSA credentials; no keys anywhere. EKS injects `AWS_ROLE_ARN` and the token file because of the service account annotation |
| 4 | The UI is reachable only through cluster credentials; the initial password no longer exists in the cluster |
| 5 | Manual changes in the cluster do not survive: Git is the source of truth |
| 6 | The only way to change the cluster is a commit, which is reviewed and recorded in Git history |

The first real load balancer is created by the application's Ingress on Day 5 (end-to-end test of the controller).

**Notes**
- A plain `helm list -A` shows only `argocd`. The controller is rendered and applied by ArgoCD, so it appears as an
  ArgoCD Application, not as a Helm release.
- `git revert <commit> && git push` undoes a change the same way: through Git.

| Setting | Why |
|---|---|
| ArgoCD installed with Helm by hand, everything else by ArgoCD | Something has to install ArgoCD first; after that, Git is the only way in |
| `server.service.type: ClusterIP` + port-forward | The ArgoCD UI is never on the internet; access needs cluster credentials |
| `exec.enabled: false`, Dex off, notifications off | Fewer features = smaller attack surface; turned on when needed |
| `timeout.reconciliation: 60s` (was 180s) | How often each app checks Git: a merge reaches the cluster within ~1–2 min. The UI "Refresh" button checks at once. Instant sync needs a GitHub webhook to `/api/webhook`, which requires ArgoCD to be reachable (Phase 2) |
| AppProject `platform` | Add-ons may only come from this repository and listed chart repositories |
| Root app has no finalizer | Deleting `root` by mistake does not delete the whole platform |
| `prune` + `selfHeal` | Removing a file removes the component; manual cluster edits are reverted |
| Load balancer controller stays in `kube-system` | Matches the AWS documentation and the IRSA trust (`kube-system:aws-load-balancer-controller`). Moving it would need the Terraform trust changed first, then the Git change |
| Load balancer controller `vpcTags: Name=platform-dev` | Pods cannot read instance metadata (hop limit 1), so the VPC is found by its tag, not by asking the node |
| `enableServiceMutatorWebhook: false` | The controller handles Ingresses only and does not take over other Services |
| Chart versions pinned (ArgoCD 10.10.1, controller 3.6.0) | Upgrades are reviewed one-line changes |
| ArgoCD chart pulled from `oci://ghcr.io/argoproj/argo-helm` | The https chart repository serves files from GitHub release assets, which timed out on this network; the OCI copy is the same chart (digest `sha256:1320fc2d…`) |

---

## 10c. Step 8: Platform Add-ons (Day 4)

Three add-ons, all installed by ArgoCD from `gitops/platform/`. Only Karpenter needs AWS resources first.

> **How Karpenter and External Secrets work** (diagrams, where they run, which file holds what, read-only
> checks): [docs/karpenter-and-external-secrets.md](docs/karpenter-and-external-secrets.md)

| Add-on | Job | AWS side |
|---|---|---|
| Karpenter | Launches and removes **Spot** nodes for application pods, picks instance types per workload, consolidates underused nodes | Terraform (below) |
| External Secrets Operator | Copies Secrets Manager secrets into Kubernetes Secrets | IRSA role from Day 2 |
| Default-deny network policies | Pods may only talk to what is explicitly allowed | None (VPC CNI network policy agent, Day 2) |

### Karpenter: AWS resources (Terraform)
Code: `module "karpenter"` and the `eks-pod-identity-agent` add-on in `terraform/modules/eks/main.tf`.

| Created | Name | Purpose |
|---|---|---|
| EKS add-on | `eks-pod-identity-agent` | Gives pods AWS credentials through EKS Pod Identity |
| Controller IAM role + Pod Identity association | `platform-dev-karpenter` ↔ `kube-system/karpenter` | Lets the controller launch/terminate EC2 instances, read pricing and SSM AMI parameters |
| Node IAM role + instance profile | `platform-dev-karpenter-node` | Identity of the nodes Karpenter launches (join the cluster, pull from ECR, SSM access) |
| EKS access entry (type EC2_LINUX) | for the node role | Lets those nodes register with the cluster (authentication mode `API`) |
| SQS queue + EventBridge rules | `platform-dev-karpenter` | Spot interruption warnings (~2 min), rebalance recommendations, instance state changes: Karpenter drains the node in time |

**Pod Identity instead of IRSA for Karpenter.** The Karpenter sub-module of the EKS module (v21) supports only
EKS Pod Identity. It is AWS's newer mechanism with the same result: short-lived credentials for one service
account, no keys. The difference: the link "service account → role" is an EKS API object (Pod Identity
association) instead of an OIDC trust condition in the role. Other workloads keep IRSA.

```bash
cd ~/workspace/Task/aws-platform/terraform/environments/dev

# One time per account: Spot needs its service-linked role (an error "has been taken" means it already exists)
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true

terraform init                     # the karpenter sub-module is new
terraform plan -out=tfplan         # expect only additions: ~15 to add, 0 to change, 0 to destroy
terraform apply tfplan
terraform output karpenter         # controller role, node role name, queue name (used in the Helm values)

# Check
aws eks list-pod-identity-associations --cluster-name platform-dev --output table
kubectl get pods -n kube-system -l app.kubernetes.io/name=eks-pod-identity-agent    # one per node, Running
```
Result in this build: `Plan: 23 to add, 1 to change, 4 to destroy` (Karpenter's AWS side; ECR `force_delete`
in place; the 4 interface endpoints removed for POC cost). Applied; outputs `platform-dev-karpenter`,
`platform-dev-karpenter-node`, queue `platform-dev-karpenter`; Pod Identity association `kube-system/karpenter`;
2 Pod Identity agents running; `AWSServiceRoleForEC2Spot` present.

### The three add-ons (GitOps)
```
gitops/platform/                              (picked up by the root app)
├── repositories.yaml        OCI chart registries for Karpenter and External Secrets (public, no credentials)
├── projects.yaml            + public.ecr.aws/karpenter, ghcr.io/external-secrets/charts allowed
├── karpenter.yaml           chart 1.15.0 → kube-system (Pod Identity, interruption queue, system nodes)
├── karpenter-nodes.yaml     → platform-config/karpenter/        (sync wave 1, retries until CRDs exist)
├── external-secrets.yaml    chart 2.12.0 → external-secrets (IRSA role platform-dev-external-secrets)
├── external-secrets-store.yaml → platform-config/external-secrets/ (sync wave 1, retries)
└── app-namespaces.yaml      → platform-config/namespaces/
gitops/platform-config/                       (plain manifests, each folder owned by one Application)
├── karpenter/ec2nodeclass.yaml   HOW nodes are built
├── karpenter/nodepool.yaml       WHICH nodes are allowed
├── external-secrets/cluster-secret-store.yaml
└── namespaces/{dev,staging,production}.yaml   namespace + 3 network policies each
```

| Setting | Value | Why |
|---|---|---|
| Karpenter on system nodes | `nodeSelector: node-role: system` | It must never run on a node it manages (it could remove its own node) |
| Karpenter `AWS_REGION` env | `ap-south-1` | Pods cannot read instance metadata (hop limit 1) |
| EC2NodeClass image | `al2023@latest` | POC: always the newest EKS-optimised Amazon Linux 2023. Production: pin a dated version |
| EC2NodeClass subnets / security groups | by tag `karpenter.sh/discovery: platform-dev` | Set by the vpc and eks modules: no IDs in Git |
| EC2NodeClass `kubelet.maxPods: 110`, IMDSv2 hop limit 1, encrypted 30 Gi gp3 | | Same as the system nodes |
| NodePool `apps` | Spot; t/m/c families, 2–4 vCPU, generation > 2; label `node-role: apps` | Cheap; several families = more Spot capacity pools = fewer interruptions. App pods select `node-role: apps` |
| NodePool limits | 8 vCPU, 32 Gi | Hard ceiling on what Karpenter may launch: cost guard |
| NodePool `expireAfter: 168h` | | Every node replaced at least weekly with a fresh image |
| NodePool consolidation | `WhenEmptyOrUnderutilized` after 1 min | Removes empty nodes and repacks pods onto fewer nodes |
| ClusterSecretStore `aws-secrets-manager` | No `auth` block; `conditions` → dev, staging, production | Uses the operator's IRSA role (no keys); other namespaces cannot use the store |
| Namespaces | Pod Security `restricted` (enforce, audit, warn) | Pods must run as non-root, drop capabilities, no privilege escalation |
| `default-deny-all` | All ingress and egress blocked | Nothing talks unless allowed below |
| `allow-dns-egress` | To CoreDNS (kube-system) on 53 UDP/TCP | Name lookups still work |
| `allow-from-load-balancer` | From `10.0.96.0/22` (public subnets) to `my-app` pods on 8080 | Only the ALB reaches the app (target type `ip`) |
| Charts over OCI | Karpenter (public ECR), External Secrets (ghcr.io) | The https chart repos download from GitHub release assets, which time out on this network |

Verified before pushing: both charts render with these values (`helm template`), all 14 manifest files parse,
and every Karpenter field exists in its v1 CRD schema.

### Verify after ArgoCD has synced
```bash
kubectl get applications -n argocd                        # 7 apps Synced/Healthy (karpenter-nodes and
                                                          # external-secrets-store may retry once: CRDs first)
# Karpenter
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide   # 2 Running, system nodes
kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo   # True
kubectl get nodepool apps
kubectl logs -n kube-system deploy/karpenter --tail=30 | grep -iE "error|denied" || echo "no errors"

# External Secrets
kubectl get pods -n external-secrets                      # controller, webhook, cert-controller Running
kubectl get clustersecretstore aws-secrets-manager        # READY True (it can reach Secrets Manager)

# Namespaces and network policies
kubectl get ns dev staging production --show-labels | grep -o 'enforce=restricted' | wc -l    # 3
kubectl get networkpolicy -A                              # 3 per namespace
```

**Functional tests**
```bash
# 1. Karpenter launches a Spot node for a pod that asks for node-role=apps
kubectl create deployment karpenter-test -n default --image=public.ecr.aws/docker/library/busybox:stable -- sleep 3600
kubectl patch deployment karpenter-test -n default -p '{"spec":{"template":{"spec":{"nodeSelector":{"node-role":"apps"}}}}}'
kubectl get nodeclaims -w                                 # a NodeClaim appears, Ready in ~1 min
kubectl get nodes -L node-role,karpenter.sh/capacity-type # new node: apps, spot
kubectl delete deployment karpenter-test -n default       # node removed ~1 min later (consolidation)

# 2. External Secrets copies a secret (needs a value stored in platform-dev/my-app/dev first)
cat <<'EOT' | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: eso-test, namespace: dev }
spec:
  secretStoreRef: { kind: ClusterSecretStore, name: aws-secrets-manager }
  target: { name: eso-test }
  dataFrom: [ { extract: { key: platform-dev/my-app/dev } } ]
EOT
kubectl get externalsecret eso-test -n dev                # STATUS SecretSynced
kubectl get secret eso-test -n dev -o jsonpath='{.data}'; echo
kubectl delete externalsecret eso-test -n dev

# 3. Default deny blocks traffic, DNS still works
kubectl run np-test -n dev --rm -it --restart=Never --image=public.ecr.aws/docker/library/busybox:stable \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"np-test","image":"public.ecr.aws/docker/library/busybox:stable","command":["sh","-c","nslookup kubernetes.default; wget -T 5 -qO- https://aws.amazon.com || echo BLOCKED"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# expected: a DNS answer, then BLOCKED
```

---

## 10d. Step 9: The Application (Day 5)

Two repositories, as in the design: **code** in `AjinOrg/my-app`, **how it runs** in `AjinOrg/aws-platform`.

```
my-app repo                                  aws-platform repo
├── src/app.js, src/server.js   the service  ├── helm/my-app/                    HOW it runs (chart)
├── test/app.test.js            7 tests      │   ├── values.yaml                  defaults
├── Dockerfile                  distroless   │   └── templates/  deployment, service, ingress, hpa,
├── package.json / eslint                    │                   pdb, serviceaccount, externalsecret
└── README.md                                ├── gitops/apps/my-app.yaml          AppProject "apps" + ApplicationSet
                                             └── gitops/apps/my-app/values-{dev,staging,production}.yaml
                                                                              image tag + per-env settings
```

### The application (`my-app`)
- Node.js 22, **no runtime dependencies** (nothing third-party to patch or exploit).
- `/healthz` (liveness), `/readyz` (readiness, also the ALB health check); any other path returns app info.
- Reads secrets from **files** (`/etc/my-app/secrets/<KEY>`) on every use: a changed secret arrives without a
  restart. Handles `SIGTERM` for zero-downtime rollouts. Keep-alive longer than the ALB idle timeout.
- Image: multi-stage build, **distroless** runtime (no shell), **non-root** (uid 65532), read-only filesystem.

Verified locally: lint OK, 7/7 tests pass, the container runs with `--read-only --cap-drop ALL`, serves `/dev`,
and reads a mounted secret file; `sh` does not exist in the image.

### The chart (`helm/my-app`)

| Object | Key settings | Why |
|---|---|---|
| Deployment | No `replicas` (HPA owns it); `maxUnavailable: 0`; `nodeSelector: node-role: apps`; spread over zones and nodes | Zero-downtime rollouts; runs on Karpenter Spot nodes; one interruption does not take all replicas |
| Pod security | `runAsNonRoot`, uid 65532, `readOnlyRootFilesystem`, drop ALL capabilities, no privilege escalation, `RuntimeDefault` seccomp | Passes Pod Security `restricted` on the namespaces |
| Probes | startup + liveness `/healthz`, readiness `/readyz`; `preStop` sleep 10 s | Traffic only to ready pods; ALB stops sending before shutdown |
| ServiceAccount `my-app` | IRSA `platform-dev-my-app`; `automountServiceAccountToken: false` | Own AWS identity (no permissions yet); no Kubernetes API token |
| ExternalSecret `my-app` | `platform-dev/my-app/<env>` → Secret `my-app`, refresh 1 h | Values only in Secrets Manager |
| Secret volume | Whole volume at `/etc/my-app/secrets` (no `subPath`), `optional: true`, mode 0400 | Updates reach the pod; pod starts before the first sync |
| Service | ClusterIP, port 80 → 8080 | Only reachable through the Ingress |
| Ingress | Class `alb`; **IngressGroup `my-app`** (one shared ALB); path `/dev`, `/staging`, `/production`; HTTP 80; target type `ip`; health check `/readyz` | One load balancer instead of three (cost); no domain, so environments are told apart by path |
| HPA | CPU 70 %; min/max dev 1/3, staging 2/6, production 3/20 | Design values; needs metrics-server (EKS add-on, added to Terraform) |
| PDB | `maxUnavailable: 1` | Consolidation/upgrades remove at most one pod at a time (works with 1 replica too) |

Checked: `helm lint` OK; renders 7 objects per environment; **kubeconform** (strict, incl. ExternalSecret CRD
schema): 21/21 valid; rendering without `image.tag` fails with "image.tag is required".

### ArgoCD (`gitops/apps/my-app.yaml`)
- **AppProject `apps`:** only this repository; only namespaces `dev`, `staging`, `production`; only the 7 object
  kinds the chart needs; **no cluster-wide objects**. Stricter than `platform`.
- **ApplicationSet `my-app`:** generates `my-app-dev`, `my-app-staging`, `my-app-production`. Each uses two
  sources from this repository: the chart (`helm/my-app`) and its values file (`$values/gitops/apps/my-app/values-<env>.yaml`).
- The root app already includes `apps/*.yaml`: no change to `root-app.yaml`.
- `scripts/platform-stop.sh` now deletes ApplicationSets before Applications (otherwise they would be re-created).

### Deploy (first time, by hand; Day 6 automates the image part)
```bash
# 0. Terraform: metrics-server add-on (for the HPA)
cd ~/workspace/Task/aws-platform/terraform/environments/dev
terraform plan -out=tfplan        # expect: 1 to add (aws_eks_addon metrics-server)
terraform apply tfplan

# 1. Secret values (one JSON per environment)
for ns in dev staging production; do
  aws secretsmanager put-secret-value --secret-id platform-dev/my-app/$ns \
    --secret-string "{\"GREETING\":\"hello from $ns\"}"
done

# 2. Commit the app, build and push the image (tag = commit SHA; ECR tags are immutable)
cd ~/workspace/Task/my-app
git add -A && git commit -m "my-app: service, tests, Dockerfile" && git push
TAG=$(git rev-parse --short HEAD)
REPO=471112815218.dkr.ecr.ap-south-1.amazonaws.com/my-app
aws ecr get-login-password | docker login --username AWS --password-stdin ${REPO%/*}
docker build -t $REPO:$TAG . && docker push $REPO:$TAG
aws ecr describe-image-scan-findings --repository-name my-app --image-id imageTag=$TAG \
  --query imageScanFindings.findingSeverityCounts      # ECR basic scan on push

# 3. Point the three environments at that tag, push → ArgoCD deploys
cd ~/workspace/Task/aws-platform
sed -i "s/REPLACE_WITH_IMAGE_TAG/$TAG/" gitops/apps/my-app/values-*.yaml
git add -A && git commit -m "Day 5: deploy my-app $TAG to dev, staging, production" && git push
```

### Verify
```bash
kubectl get applications -n argocd | grep my-app        # 3 × Synced / Healthy
kubectl get pods -n dev -o wide                          # Running on a node-role=apps (Spot) node
kubectl get nodeclaims                                   # Karpenter launched the node
kubectl get externalsecret,secret my-app -n dev          # SecretSynced
kubectl get hpa -n production                            # TARGETS shows a CPU %, 3 replicas
ALB=$(kubectl get ingress my-app -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$ALB/dev; echo; curl -s http://$ALB/staging; echo; curl -s http://$ALB/production; echo
# each answers with its environment and "greeting":"hello from <env>"
```

---

## 10e. Step 10: CI Pipelines (Day 6)

Two pipelines, one per repository. Pull requests get **checks only** (no AWS access); `main` of `my-app`
additionally **publishes** the image and proposes the deployment.

```
my-app  (.github/workflows/pipeline.yaml)
  PR only ────────┬─ Gitleaks (full history)
  (branch must be ├─ Lint + unit tests + coverage (Node 22) → SonarQube Cloud (Phase 2: skipped with a warning)
   up to date     ├─ npm audit + OWASP Dependency-Check (CVSS ≥ 7 fails; needs secret NVD_API_KEY)
   with main)     └─ Trivy filesystem (vulnerabilities, secrets, Dockerfile misconfigurations)
                           │ all green
                           ▼
  PR and main     Build image (tag = 7-char commit SHA) → Trivy image (HIGH/CRITICAL with a fix fail)
                  → Kyverno: platform policies applied to the platform's chart with THIS image
                           │ main only (lighter run: the checks above already passed on the up-to-date PR)
                           ▼
                  GitHub OIDC → role aws-platform-ecr-push (1 h) → push to ECR (skipped if the tag exists)
                  → GitHub App token → pull request in aws-platform: values-dev.yaml image.tag = <sha>

aws-platform  (.github/workflows/platform-ci.yaml)
  PR / push main ─┬─ Gitleaks (full history)
                  ├─ Terraform fmt + validate (every environment)
                  ├─ Helm lint + render 3 envs + kubeconform (all manifests, CRD schemas)
                  │   + Kyverno: chart must pass, every demo/bad-*.yaml must be rejected
                  └─ Checkov (Terraform, CloudFormation, rendered chart; skips with reasons in .checkov.yaml)
```

### New files

| Repository | File | Purpose |
|---|---|---|
| both | `.github/scripts/install-ci-tools.sh` | Installs **pinned** Gitleaks 8.30.1, Trivy 0.75.0, kubeconform 0.8.0, Kyverno CLI 1.19.1; every download checked against the official SHA256 file |
| aws-platform | `.github/workflows/platform-ci.yaml` | Platform checks (above) |
| aws-platform | `.checkov.yaml` | Checkov frameworks + 8 skipped checks, each with its reason |
| aws-platform | `.github/CODEOWNERS` | Required reviewer for production values, Terraform, bootstrap, policies, pipelines |
| aws-platform | `policies/kyverno/*.yaml` | 6 policies, `Enforce`, for namespaces dev/staging/production (below) |
| aws-platform | `demo/bad-*.yaml` | 4 deliberately non-compliant Deployments: each must be rejected |
| my-app | `.github/workflows/pipeline.yaml` | Application pipeline (above) |

### Kyverno policies

| Policy | Rejects |
|---|---|
| `disallow-privileged-containers` | `securityContext.privileged: true` |
| `require-run-as-non-root` | Pods/containers without `runAsNonRoot: true` |
| `restrict-image-registries` | Images not from `471112815218.dkr.ecr.ap-south-1.amazonaws.com` |
| `require-requests-limits` | Containers without CPU/memory requests or a memory limit (CPU limits deliberately not required) |
| `disallow-latest-tag` | `:latest` or no tag |
| `require-probes` | Containers without liveness and readiness probes |

Used today by the **CI** (Kyverno CLI). Installing Kyverno in the cluster to enforce them at admission is the
next step (Day 8 in the plan); the files are already in the format the cluster needs.

### Checked before pushing (locally, same versions as CI)

| Check | Result |
|---|---|
| `install-ci-tools.sh` | All 4 downloads: checksum OK |
| actionlint (both workflows) | No problems |
| Gitleaks (aws-platform history) | No leaks |
| kubeconform: 48 resources (3 rendered envs + all gitops manifests) | 47 valid; `ClusterSecretStore` v1 has no public schema, so that kind alone is skipped |
| Kyverno: chart in dev / staging / production | `pass: 7, fail: 0` each |
| Kyverno: `bad-privileged`, `bad-root`, `bad-registry`, `bad-no-limits` | Each **rejected** by exactly its policy (exit code 1) |
| Checkov | 0 failed (one real finding fixed: explicit KMS key policy in the secrets module) |
| Trivy fs, npm audit (my-app) | Clean |
| Trivy image | **First run failed**: 1 critical + 5 high OpenSSL CVEs in the Debian 12 distroless base (also in the running image `20f4799`). Fixed by moving to `gcr.io/distroless/nodejs22-debian13:nonroot`: now clean |

### Checkov: accepted findings (`.checkov.yaml`)

| Check | Why accepted |
|---|---|
| `CKV_TF_1` module commit hash | Registry modules pinned with `~>`; providers by the lock file |
| `CKV_AWS_394` AZ pinning | First 3 AZs taken explicitly |
| `CKV2_AWS_57` secret rotation | Rotated by owners (POC); needs a rotation Lambda |
| `CKV_AWS_18` state bucket access logs | CloudTrail; extra log bucket not worth it for the POC |
| `CKV_K8S_43` image digest | ECR tags are immutable |
| `CKV_K8S_15` pull policy Always | Immutable tags make `IfNotPresent` safe |
| `CKV_K8S_11` CPU limits | Deliberate: throttling; memory limits are enforced |
| `CKV2_K8S_6` NetworkPolicy | Applied per namespace by the platform, not by the chart |

### One-time GitHub settings
Branch protection (rulesets), the GitHub App, SonarQube Cloud and the NVD key are set up in
[Step 11: Continuous Delivery](#10f-step-11-continuous-delivery-dev--staging--production).

---

## 10f. Step 11: Continuous Delivery (dev → staging → production)

**Principle: approve releases, not commits.** Every check runs on every change. Dev follows every commit
automatically; staging and production move only when a person **chooses a tested tag and starts the release**.

```
developer push to my-app main
   │ my-app pipeline: Gitleaks · lint · tests + coverage · SonarQube Cloud quality gate · npm audit/OWASP
   │                  · Trivy fs · build · Trivy image · Kyverno  → push image to ECR (OIDC)
   ▼
DEV         PR deploy/dev/my-app-<sha> → platform-ci green → merges ITSELF            → ArgoCD syncs
            verify.yaml: waits until /dev serves <sha> → smoke tests  ✅  (nothing moves on by itself)
   │
   │  a person tests dev, then STARTS the release (form "Run workflow" or scripts/release.sh menu)
   │  release.yaml checks: tag is a 7-char SHA · has run in dev · exists in ECR · not already in staging
   ▼
STAGING     PR deploy/staging/my-app-<sha> → platform-ci green → merges ITSELF         → ArgoCD syncs
            verify.yaml: smoke tests on /staging ✅
   │
   │  a person STARTS the production release (tag must have run in staging)
   ▼
PRODUCTION  PR deploy/production/my-app-<sha> → platform-ci green → Code Owner APPROVES → ArgoCD syncs
            verify.yaml: smoke tests on /production ✅
```

| Environment | Moves when | Confirmations | Checks before it changes |
|---|---|---|---|
| dev | every merge to my-app `main` | none (automatic) | all my-app checks + platform-ci |
| staging | a person starts **release → staging** and picks a tag | 1: starting the release | tag ran in dev, exists in ECR; platform-ci |
| production | a person starts **release → production** and picks a tag | 2: starting the release + Code Owner approval | tag ran in staging, exists in ECR; platform-ci |

### Releasing (the "popup" and the tag list)
**Option A: GitHub form.** GitHub → `AjinOrg/aws-platform` → **Actions → release → Run workflow**: choose
`staging` or `production`, type the tag (empty = the tag running now in the previous environment) → **Run workflow**.
The run summary lists the tags that have run in the previous environment.

**Option B: menu in the terminal** (lists the tested tags to pick from):
```bash
cd ~/workspace/Task/aws-platform
bash scripts/release.sh
#  1) staging   2) production                      ← choose
#  Now running:  dev = 1e0f51f   staging = 1e0f51f
#  1) 1e0f51f  (in dev since 2026-10-12 12:38)      ← pick a tested tag
#  2) 20f4799  (in dev since 2026-10-12 09:25)
#  Type the environment name (staging) to confirm:  ← confirm
```
GitHub's form cannot show a live dropdown of tags (its options are fixed in the workflow file), which is why the
form takes the tag as text and the script provides the pick-list.

**Rollback** is the same action with an older tag: `scripts/release.sh` → pick the previous tag (it has run there
before, so it is accepted) → confirm.

**How the confirmations are enforced:** one ruleset on `main` requires a pull request, green checks and *review
from Code Owners*, with 0 other approvals. `CODEOWNERS` gives `values-dev.yaml` and `values-staging.yaml` no owner
and `values-production.yaml` the platform team. Staging changes only through `release.yaml`, which a person must
start (only people with write access can run workflows); production additionally needs the Code Owner's approval.

| Situation | Handling |
|---|---|
| Several my-app pushes close together | One dev deployment job at a time; a newer tag closes older open dev PRs ("superseded") |
| A release requested twice | Only the newest release PR per environment stays open |
| Tag never ran in the previous environment | `release.yaml` refuses it (no skipping dev, no skipping staging) |
| Smoke test fails | `verify.yaml` fails and shows why; release an earlier tag to roll back |
| Dev rebuilt (new ALB address, empty ECR) | `verify.yaml` finds the ALB by tag `ingress.k8s.aws/stack=my-app`; `release.yaml` refuses tags missing from ECR |
| PR opened by `GITHUB_TOKEN` | Would not trigger platform-ci: all deployment PRs use the GitHub App token |

**Files**

| Repository | File | Purpose |
|---|---|---|
| my-app | `.github/workflows/pipeline.yaml` | Job *Code quality (SonarQube Cloud)*; tests with coverage; dev PR with auto-merge, superseding older PRs |
| my-app | `sonar-project.properties`, `package.json` (`test:coverage`) | Sonar settings; coverage via Node's built-in lcov reporter (app.js: 100 % lines) |
| aws-platform | `.github/workflows/verify.yaml` | After any tag change: wait for the rollout, smoke-test that environment. Verifies only |
| aws-platform | `.github/workflows/release.yaml` | Started by a person: validate the tag, open the staging or production PR |
| aws-platform | `scripts/release.sh` | Terminal menu: pick environment and tested tag, confirm, start `release.yaml` |
| aws-platform | `.github/CODEOWNERS` | dev and staging values without owner; production values owned |
| aws-platform | `.github/rulesets/*.json` | Branch rules for both repositories, as code |

### Pipeline speed: why checks run twice, and planned improvements
The my-app checks run on the **pull request** and again on **main** after the merge.

| Run | What it tests | Pushes / deploys |
|---|---|---|
| Pull request | The change, merged with main *as it was when the checks started* | Nothing (build + scans only, so a broken Dockerfile or vulnerable image is caught before merge) |
| main | Exactly what is on main (it also has to build: a squash merge creates a new commit SHA = the image tag) | Image to ECR, dev deployment PR |

Why main re-checks: two PRs can each be green but break when combined (both merged before either was tested with
the other). Today a PR run takes ~1.5 min and a main run ~2–2.5 min; jobs run in parallel and Actions minutes are
free on public repositories.

**Planned improvements (not implemented yet)**

| # | Option | Saves | Trade-off | When |
|---|---|---|---|---|
| A | **Caching:** Docker layer cache (`docker/build-push-action` with `cache-from/cache-to: type=gha`), Trivy vulnerability database (`actions/cache` on `~/.cache/trivy`), npm (already cached) | 30–50 % per run | None | Next change to the pipeline |
| B | **Lighter main run:** only build, Trivy image and push on main; lint, tests, Sonar, dependency and filesystem scans only on PRs | ~1 min per merge | Without C, main is no longer re-tested after combining PRs | Together with C |
| C | **GitHub merge queue:** PRs are tested combined, in merge order, before they reach main (workflow trigger `merge_group`; ruleset rule `merge_queue`) | Makes B safe: nothing untested reaches main | "Merge when ready" instead of an immediate merge; a few minutes in the queue under load | When several developers merge daily |
| D | **Build once:** the image tested in the queue is the image deployed (tag by the queue's commit, or rebase merges so SHAs match) | One build per change | Needs C (or rebase merges) | Larger teams |

Usual path: **A now; C + B when the team grows; D for large teams.** What slows big pipelines is mostly slow tests,
not running checks twice: split tests, run only what changed, keep jobs parallel.

**Implemented: B with the "branch must be up to date" rule instead of a merge queue** (A, C, D remain planned)

```
PR to my-app main:  Gitleaks · lint + tests · Sonar · dependencies · Trivy fs · build · Trivy image · Kyverno
                    → branch must contain the latest main → all green → merge
my-app main:        build → Trivy image → push to ECR → dev deployment PR in aws-platform (unchanged)
```

| Change | Where |
|---|---|
| The 5 check jobs run on pull requests only; build + Trivy image (+ Kyverno) on both; push and dev PR on main | `my-app/.github/workflows/pipeline.yaml` |
| `strict_required_status_checks_policy: true` ("Require branches to be up to date before merging") | `.github/rulesets/my-app-main.json` (my-app only) |

- **Why the up-to-date rule makes the lighter main run safe:** a PR can merge only if it already contains the latest
  main, so the checks ran on exactly the code that lands on main. Nothing untested reaches main.
- **Trivy image stays on main** (~14 s): protects against a CVE published between the PR check and the merge.
- **Not on aws-platform:** there it would hold every bot PR back whenever another PR merges; bot PRs change one line each.
- **Cost for developers:** sometimes clicking **Update branch** (explained below). Move to the merge queue (C) when
  that happens many times a day.

**The "Update branch" step, by example**
```
09:00  Dev A opens PR-1 (based on main@v1) → checks green
09:05  Dev B opens PR-2 (based on main@v1) → checks green
09:10  PR-1 merged → main is now v2 (contains PR-1)
09:11  PR-2 shows "This branch is out-of-date with the base branch" → Merge is blocked
       Dev B clicks "Update branch" (or: git pull origin main && git push)
       → PR-2 now = v1 + PR-1 + PR-2 → checks run again on that combination (~1.5 min)
09:13  green → merge. What was tested is exactly what main becomes.
```
Without the rule, PR-2 would merge with checks that never saw PR-1: fine most of the time, but when PR-1 and PR-2
touch related code (one renames a function the other calls), main breaks and nobody tested it. The extra effort is
one click plus one check run, and only when main moved after the PR was checked. Commands:
`gh pr update-branch <number>` or, locally, `git fetch origin && git merge origin/main && git push`.

### Setup 1: GitHub App (opens the deployment PRs)
1. https://github.com/organizations/AjinOrg/settings/apps/new
   - Name: e.g. `ajinorg-deployer` (must be unique on GitHub); Homepage URL: `https://github.com/AjinOrg`
   - Webhook: **untick Active**
   - Repository permissions: **Contents: Read and write**, **Pull requests: Read and write** (Metadata: read, automatic)
   - Where can it be installed: **Only on this account** → Create
2. Note the **App ID**; *Generate a private key* (downloads a `.pem`).
3. *Install App* → AjinOrg → **Only select repositories** → `aws-platform`.
4. Store the ID and key in both repositories, then delete the local key file:
```bash
APP_ID=<app-id>; KEY=/mnt/c/Users/<you>/Downloads/<name>.private-key.pem
for r in my-app aws-platform; do
  gh variable set PLATFORM_APP_ID -R AjinOrg/$r --body "$APP_ID"
  gh secret set PLATFORM_APP_PRIVATE_KEY -R AjinOrg/$r < "$KEY"
done
shred -u "$KEY" 2>/dev/null || rm -f "$KEY"
```
The app can write only to `aws-platform`, and only contents and pull requests; its tokens live 1 hour.

### Setup 2: SonarQube Cloud (Phase 2)
Not set up in Phase 1. The pipeline job "Code quality (SonarQube Cloud)" already exists: without the `SONAR_TOKEN`
secret it shows a warning and passes, so it does not block anything. To enable it later:
1. https://sonarcloud.io → *Log in with GitHub* → *Import an organization* → `AjinOrg` (installs the SonarQube Cloud
   app; select `my-app`) → organization key `ajinorg`, **free plan** (public repositories).
2. *Analyze new project* → `my-app` → method **GitHub Actions** → copy the token:
   `gh secret set SONAR_TOKEN -R AjinOrg/my-app`
3. Project → *Administration → Analysis Method* → **turn off Automatic Analysis** (the pipeline does the analysis).
4. Check that organization and project key match `sonar-project.properties` (`ajinorg`, `AjinOrg_my-app`); adjust the
   file if SonarQube Cloud shows different keys.
5. Quality gate: the default *Sonar way* (new code: coverage ≥ 80 %, no new bugs/vulnerabilities, duplication ≤ 3 %).
   The job waits for the gate (`sonar.qualitygate.wait=true`): a failed gate fails the pipeline.

### Setup 3: Rulesets (branch protection) and auto-merge
Rulesets instead of classic branch protection: they support the Code Owner rule above and an admin bypass for a
single maintainer. The JSON files are in `.github/rulesets/`.
```bash
cd ~/workspace/Task/aws-platform
gh repo edit AjinOrg/aws-platform --enable-auto-merge --delete-branch-on-merge
gh repo edit AjinOrg/my-app       --delete-branch-on-merge
# Create the ruleset, or update it if it already exists (safe to re-run; the file is the source of truth)
for r in aws-platform my-app; do
  ID=$(gh api repos/AjinOrg/$r/rulesets --jq '.[] | select(.name=="main") | .id')
  if [ -n "$ID" ]; then
    gh api -X PUT  repos/AjinOrg/$r/rulesets/$ID --input .github/rulesets/$r-main.json --jq '"\(.id) \(.name) \(.enforcement) (updated)"'
  else
    gh api -X POST repos/AjinOrg/$r/rulesets     --input .github/rulesets/$r-main.json --jq '"\(.id) \(.name) \(.enforcement) (created)"'
  fi
done
gh repo view AjinOrg/aws-platform --json autoMergeAllowed,deleteBranchOnMerge     # both true
```

| Setting | Why |
|---|---|
| Pull request required, no force push, no branch deletion | `main` changes only through checked PRs |
| `require_code_owner_review` + 0 approvals (aws-platform) | Approval only where CODEOWNERS names an owner (production, infrastructure) |
| `strict_required_status_checks_policy: false` | Bot PRs do not have to be rebased on every new commit to main (would block auto-merge under load); each PR changes one line |
| aws-platform bypass: repository admins, mode `pull_request` | A single maintainer cannot approve their own PR; admins may merge a PR past the rules, but cannot push to main directly. Remove the bypass when a second Code Owner exists |
| my-app: **no bypass**, 0 approvals, **branch must be up to date** (`strict: true`) | Nobody (admins included) can merge without green checks; with 0 approvals nobody needs a bypass. Raise approvals to 1 when the team grows |

### Access for developers
Developers work in `my-app` through pull requests; the platform team owns `aws-platform`, releases and approvals.

| Team | `my-app` | `aws-platform` | Can | Cannot |
|---|---|---|---|---|
| `developers` | **Write** | **Read** | Push branches, open/merge PRs in my-app when checks are green; see the platform code and the Actions runs | Bypass checks, change settings or rulesets, change infrastructure, run release.yaml, approve production |
| `platform` (Code Owners) | Admin / Maintain | **Write** (+ admin for one owner) | Run `release.yaml`, approve production PRs, change infrastructure through reviewed PRs | Merge their own owned changes without another owner's review (once the aws-platform bypass is removed) |

```bash
# Organization: no default access to repositories
gh api -X PATCH orgs/AjinOrg -f default_repository_permission=read

# Teams
gh api -X POST orgs/AjinOrg/teams -f name=developers -f privacy=closed
gh api -X POST orgs/AjinOrg/teams -f name=platform   -f privacy=closed
gh api -X PUT orgs/AjinOrg/teams/developers/repos/AjinOrg/my-app       -f permission=push   # Write
gh api -X PUT orgs/AjinOrg/teams/developers/repos/AjinOrg/aws-platform -f permission=pull   # Read
gh api -X PUT orgs/AjinOrg/teams/platform/repos/AjinOrg/aws-platform   -f permission=push   # Write
gh api -X PUT orgs/AjinOrg/teams/platform/repos/AjinOrg/my-app         -f permission=maintain

# Invite a developer (they receive an email) and add them to the team
gh api -X PUT orgs/AjinOrg/teams/developers/memberships/<github-username> -f role=member
```
Then replace `@AjinUrolime` in `CODEOWNERS` with `@AjinOrg/platform`, so any platform member can approve.

### Setup 4 (optional): NVD API key
https://nvd.nist.gov/developers/request-an-api-key → `gh secret set NVD_API_KEY -R AjinOrg/my-app`. Enables the
full OWASP Dependency-Check (without it the job runs `npm audit` and shows a warning).

### Verify the flow
```bash
# 1. A change in my-app, through a PR (rulesets are on), merged when the checks are green
# 2. Dev follows automatically:
gh run watch -R AjinOrg/my-app                                    # ends with "Dev deployment PR opened"
gh pr list -R AjinOrg/aws-platform --state all --limit 3          # deploy(dev): ... merged by itself
gh run list -R AjinOrg/aws-platform --workflow verify.yaml        # smoke test dev ✅
# 3. Release to staging on purpose:
bash scripts/release.sh                                           # staging → pick the new tag → confirm
gh run list -R AjinOrg/aws-platform --workflow verify.yaml        # smoke test staging ✅
# 4. Release to production:
bash scripts/release.sh                                           # production → pick → confirm
gh pr list -R AjinOrg/aws-platform                                # deploy(production): ... waits for approval
gh pr review <number> -R AjinOrg/aws-platform --approve           # or merge as admin → production, smoke-tested
```

---

## 10g. Step 12: Kyverno in the Cluster (policy enforcement at admission)

The 6 policies in `policies/kyverno/` already run in **CI** (Kyverno CLI). This step also enforces them **inside the
cluster**: the Kubernetes API asks Kyverno about every new or changed object before storing it.

```
kubectl / ArgoCD / any tool  ──▶  API server
                                   1. authentication + authorization
                                   2. admission: Pod Security (namespace label "restricted")
                                                 Kyverno webhook ──▶ 6 policies
                                                                      ├─ compliant → stored
                                                                      └─ violation → REJECTED with the policy message
```

| Where | When | Catches |
|---|---|---|
| CI (Kyverno CLI v1.19.1) | Every pull request | Problems before merge (fast feedback) |
| Cluster (Kyverno v1.19.1) | Every create/update in dev, staging, production | Everything else: manual `kubectl`, tools that bypass CI |

### Files
| File | Purpose |
|---|---|
| `gitops/platform/kyverno.yaml` | Chart `kyverno` 3.9.1 (Kyverno v1.19.1) from `ghcr.io/kyverno/charts` (OCI) → namespace `kyverno`; all controllers on the system nodes; admission controller ×2; webhook cleanup on uninstall |
| `gitops/platform/kyverno-policies.yaml` | Applies `policies/kyverno/` (sync wave 1, retries until Kyverno's CRDs exist); self-heal restores a policy changed or deleted by hand |
| `gitops/platform/repositories.yaml`, `projects.yaml` | OCI registry `ghcr.io/kyverno/charts` added and allowed in project `platform` |
| `policies/kyverno/*.yaml`, `demo/bad-*.yaml` | Unchanged: the same files CI uses |

| Design point | Choice | Why |
|---|---|---|
| Scope | Only `dev`, `staging`, `production` (in each policy's `match`) | Platform namespaces (`kube-system`, `argocd`, `kyverno`, ...) can never be blocked by mistake |
| Mode | `Enforce` | Proven in CI against the real chart; existing workloads comply |
| Deployments | Kyverno *autogen* applies the Pod rules to Deployments, ReplicaSets, ... | A bad Deployment is rejected as a whole, with a clear message |
| Existing workloads | Background scan → **PolicyReports** | Shows compliance of what already runs; running pods are never deleted |
| Kyverno unavailable | Webhook fails closed for the 3 app namespaces | Nothing unchecked gets in; 2 admission replicas avoid this during a restart. Production: 3 |
| Capacity | ~4 small pods (~0.5 GB) on the 2 system nodes | Check with `kubectl top nodes` |

**Two layers:** the app namespaces also have Pod Security Admission (`restricted`). For a **Deployment**, Pod
Security only *warns*; Kyverno *rejects*. Registry, tag, limits and probes are checked only by Kyverno.

| Demo file | Pod Security (restricted) | Kyverno |
|---|---|---|
| `bad-privileged.yaml`, `bad-root.yaml` | Warning | **Rejected** |
| `bad-registry.yaml` (Docker Hub image) | Not checked | **Rejected** |
| `bad-no-limits.yaml` | Not checked | **Rejected** |

Checked before pushing: chart renders (81 objects; 4 controllers on system nodes; admission ×2); kubeconform 18/18
valid (incl. the ClusterPolicy schema); Kyverno CLI v1.19.1 rejects all 4 demo files.

### Tests
```bash
# A. Installed
kubectl get applications -n argocd | grep kyverno       # kyverno, kyverno-policies → Synced/Healthy
kubectl get pods -n kyverno -o wide                      # controllers Running on system nodes
kubectl get clusterpolicy                                # 6 policies, READY True

# B. Bad workloads are rejected (the demo)
cd ~/workspace/Task/aws-platform
for f in demo/bad-*.yaml; do echo "== $f"; kubectl apply -f "$f"; done
kubectl run test -n dev --image=nginx                    # Docker Hub image → rejected

# C. Good workloads still work
kubectl get pods -n dev; kubectl get pods -n staging; kubectl get pods -n production
#   + a normal my-app change → dev updates as usual

# D. Reports for what already runs
kubectl get policyreport -A                              # PASS counts, FAIL 0

# E. Scope: other namespaces are not affected
kubectl run scope-test -n default --image=nginx --restart=Never && kubectl delete pod scope-test -n default

# F. GitOps protects the policies
kubectl delete clusterpolicy require-probes
kubectl get clusterpolicy require-probes -w              # restored by ArgoCD within ~1 min
```

### Result in this build
- `kyverno` and `kyverno-policies`: **Synced / Healthy**; 6 ClusterPolicies `READY True`.
- **Test B passed:** all 4 demo Deployments were rejected by the cluster, each by exactly its own policy. For
  `bad-privileged` and `bad-root`, Pod Security only printed a warning ("would violate PodSecurity
  restricted:latest") and Kyverno blocked them: the two layers behave as designed.

```
Error from server: ... admission webhook "validate.kyverno.svc-fail" denied the request:
resource Deployment/dev/bad-root was blocked due to the following policies
require-run-as-non-root: ... Containers must run as non-root: set securityContext.runAsNonRoot: true
```

**Lesson: permanent OutOfSync on the `policies.kyverno.io` CRDs.** The chart's sub-chart `kyverno-api` renders
`labels: {}` and `annotations: {}` on 11 CRDs. The API server drops empty maps when it stores an object, so Git and
cluster never matched (`argocd app diff` showed `> labels: {}`, then `annotations: {}`). Fix: render real values
(`kyverno-api.labels` / `.annotations` in `kyverno.yaml`) instead of ignoring the difference. Checked by rendering
the chart: no object has an empty `labels` or `annotations` map. (A first guess, a runtime-patched conversion
webhook, was ruled out with `managedFields`: only `argocd-controller` and `kube-apiserver` had written the CRD.)

**Deprecation notice:** `kubectl get clusterpolicy` warns that `kyverno.io/v1 ClusterPolicy` is deprecated in favour
of the CEL-based `ValidatingPolicy` (`policies.kyverno.io`). It still works fully; migrating the 6 policies is in
the production-grade list.

---

## 10h. Step 13: Terraform Pipeline (infrastructure through pull requests)

From now on infrastructure changes go through a pull request, exactly like everything else. Nobody runs
`terraform apply` from a laptop.

```
PR touching terraform/**
   └─ Terraform plan (dev)   OIDC → aws-platform-terraform-plan (ReadOnlyAccess + state)
        init · fmt -check · validate · plan → posted as ONE PR comment (updated on every push)
        Checkov: platform-ci · approval: CODEOWNERS (/terraform/) → merge

push to main touching terraform/**
   ├─ Terraform plan (dev)   read-only role → saved plan file (artifact, 1 day)
   └─ Terraform apply (dev)  only if the plan has changes
        ⏸ GitHub Environment "terraform-apply": waits for a required reviewer to approve (Actions UI)
        OIDC → aws-platform-terraform-apply (trusts ONLY .../aws-platform@...:environment:terraform-apply)
        terraform apply <the saved plan>   (refused as "stale" if state or code changed in between)
```

| Point | How |
|---|---|
| Read-only plans | The plan role has `ReadOnlyAccess` + the state files: a PR (even a malicious workflow change) cannot change AWS |
| Approval before apply | GitHub Environment `terraform-apply` with required reviewers; the apply role cannot be assumed from anywhere else |
| Apply what was reviewed | The plan file from main is applied as-is; a stale plan is refused, run the workflow again |
| One run at a time | `concurrency: terraform-dev` + S3 state locking (`use_lockfile`) |
| No secrets in plans | Secret values are never in Terraform (set with the CLI), so the PR comment and the artifact hold none |
| Readable plan to download | Every run uploads `tfplan.txt` (`terraform show` output, artifact `tfplan-dev-readable-<run>`, 7 days): `gh run download <run-id> -R AjinOrg/aws-platform -n tfplan-dev-readable-<run-number>`. The binary `tfplan` (1 day) is only for `terraform apply` |
| No cluster access needed | Terraform here uses only the AWS provider; GitHub runners never reach the EKS API (`admin_cidrs` unchanged) |

**Caller-independent KMS key policy.** The EKS module makes *whoever runs Terraform* the administrator of the
cluster's secrets KMS key unless `kms_key_administrators` is set. Laptop, plan role and apply role would then
flip the key policy on every run, and every PR plan would show a change nobody made. `terraform.tfvars` now lists
the administrators explicitly: the apply role and the local admin user.

### Setup (one time)
```bash
# 1. Last local apply: the fixed KMS key administrators (expect: 0 add, 1 change, 0 destroy - the key policy)
cd ~/workspace/Task/aws-platform/terraform/environments/dev
terraform init && terraform plan -out=tfplan
terraform apply tfplan && rm -f tfplan

# 2. GitHub Environment "terraform-apply" with you as required reviewer, main only
REVIEWER_ID=$(gh api users/AjinUrolime --jq .id)
gh api -X PUT repos/AjinOrg/aws-platform/environments/terraform-apply --input - <<EOF
{ "wait_timer": 0, "prevent_self_review": false,
  "reviewers": [ { "type": "User", "id": $REVIEWER_ID } ],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false } }
EOF
gh api repos/AjinOrg/aws-platform/environments/terraform-apply \
  --jq '{name, rules: [.protection_rules[] | .type], branches: .deployment_branch_policy}'
```
- `prevent_self_review: false`: a single maintainer merges and approves; set `true` when a second reviewer exists.
- `protected_branches: true`: only `main` (protected by the ruleset) can deploy to this environment.

### Tests
| # | Test | Expected |
|---|---|---|
| 1 | PR that adds the workflow (no infrastructure change) | Comment "Terraform plan: dev · `No changes.`" (plan role works: OIDC, state, lock, read-only access) |
| 2 | Merge it | Plan on main: no changes → apply job skipped |
| 3 | PR with a small change (e.g. `keep_images = 25` for the ECR module in `environments/dev/main.tf`) | Comment shows `Plan: 0 to add, 1 to change, 0 to destroy` (ECR lifecycle policy) |
| 4 | Merge it | "Terraform apply (dev)" shows **Waiting** → Actions → run → *Review deployments* → approve → applied |
| 5 | `aws ecr get-lifecycle-policy --repository-name my-app` | Shows the new count |

---

## 11. Build Progress (Days 1 to 6)

Tick each item as it is done.

**Day 1: Setup, state backend and network**
- [x] Tools installed (Step 1)
- [x] AWS access working (Step 2: profile `task`, temporary IAM user keys)
- [x] GitHub connected (Step 3: `gh` logged in as `AjinUrolime`, organization `AjinOrg` granted)
- [x] `aws-platform` repository created on GitHub (`AjinOrg/aws-platform`, public)
- [x] `my-app` repository created on GitHub (`AjinOrg/my-app`)
- [x] CloudFormation bootstrap deployed and verified (state bucket, KMS key, GitHub OIDC, pipeline roles)
- [x] VPC created with Terraform (3 AZs, NAT, endpoints, flow logs)

**Day 2: EKS cluster and supporting AWS resources**
- [x] EKS cluster `platform-dev` (1.36) and system node group (2 × t3.medium)
- [x] ECR repository, Secrets Manager secrets, IRSA roles (one apply with the VPC: 86 resources)

**Day 3: Dev environment and GitOps**
- [x] `kubectl` connected to the Dev cluster
- [x] ArgoCD installed (Helm, chart 10.10.1), app-of-apps structure in place (`root` → `platform/`)
- [x] AWS Load Balancer Controller (chart 3.6.0, IRSA), deployed by ArgoCD
- [ ] ~~Certificate, DNS record and HTTPS ingress~~ not in this build: no domain, the app uses the ALB address over HTTP (Day 5)

**Day 4: Platform add-ons**
- [x] Karpenter AWS side (Terraform: roles, Pod Identity, interruption queue)
- [x] Karpenter controller, EC2NodeClass and NodePool (ArgoCD); first Spot node launched by the my-app deploy
- [x] External Secrets Operator and ClusterSecretStore (my-app secrets synced in all 3 namespaces)
- [x] Default-deny network policies + Pod Security `restricted` on dev, staging, production

**Day 5: Application deployment**
- [x] Sample app and Dockerfile (non-root, distroless, health endpoints): `AjinOrg/my-app`, image `20f4799`
- [x] Helm chart `helm/my-app` + ApplicationSet (project `apps`), metrics-server add-on for the HPA
- [x] App deployed to the dev, staging and production namespaces behind one shared ALB (`/dev`, `/staging`, `/production`)

**Day 6: CI pipelines**
- [x] `my-app` pipeline: Gitleaks, lint, tests, npm audit + OWASP Dependency-Check (runs once the `NVD_API_KEY` secret is set), Trivy fs + image
- [x] `my-app` publishes the image to ECR with GitHub OIDC (immutable subject), no stored keys: `1e0f51f`
- [x] `aws-platform` checks: Gitleaks, Terraform fmt/validate, Helm lint, kubeconform, Kyverno, Checkov
- [x] Kyverno CLI check in `my-app` (6 policies against the platform chart with the new image)
- [x] Fixed image `1e0f51f` (OpenSSL CVEs) deployed to dev, staging, production; `platform-ci` green
- [x] Rulesets (branch protection) on both repositories (my-app: no bypass; aws-platform: admin bypass via PR until a second Code Owner)
- [x] GitHub App: automatic dev deployment PRs; staging/production released on purpose (release.yaml / scripts/release.sh)
- [x] End-to-end delivery test passed: my-app merges → dev automatic (a7ec651, edd9422, smoke-tested) → staging released with scripts/release.sh → production released + approved; ArgoCD polling reduced to 60s after observing 3-4 min delays
- [ ] Phase 2: SonarQube Cloud quality gate (pipeline job ready; skipped with a warning until the `SONAR_TOKEN` secret exists)
- [ ] Optional: NVD API key (full OWASP Dependency-Check)
- [x] Kyverno in the cluster: 6 policies enforced at admission; all 4 demo Deployments rejected (Step 12)
- [ ] Planned: pipeline caching (Docker layers, Trivy DB) (see "Pipeline speed" in Step 11)
- [x] Lighter main run (build, Trivy image, Kyverno, push) + "branch must be up to date" rule on my-app (main run ~1 min instead of ~2–2.5 min); merge queue later when the team merges many times a day

### POC scope: remaining work (agreed 2026-10-13)
The POC is complete with the items below. Production-grade work starts only after the POC is accepted.

| # | Item | Estimate | Status |
|---|---|---|---|
| 1 | Kyverno in the cluster: resolve ArgoCD OutOfSync, run tests A–F (Step 12) | 30 min | **Done** (Synced/Healthy, test B passed) |
| 2 | Terraform pipeline: plan on every PR, apply after approval (GitHub Environment `terraform-apply`) | ~2 h | Built, to test (Step 13) |
| 3 | Monitoring: Prometheus, Grafana, Loki, alerts, dashboards | ~3 h | To do |
| 4 | Load test: HPA + Karpenter scale up and down, watched in Grafana (`demo/load-test.yaml`) | 30 min | To do |
| 5 | SonarQube Cloud quality gate (pipeline job ready) | 20 min | To do |
| 6 | Project docs in `docs/`: architecture, decisions, runbook | 1.5 h | To do |

**Production-grade phase (after acceptance):** delete the temporary IAM access key (after item 2), pipeline caching
and merge queue, pin GitHub Actions to commit SHAs, pin the Karpenter AMI, remove the root cluster-admin entry,
separate secret stores per environment, NVD API key, HTTPS with a domain, AWS SSO and ArgoCD SSO, dedicated
Staging and Production clusters, Kyverno admission controller ×3, migrate the 6 ClusterPolicies to
ValidatingPolicy (CEL; ClusterPolicy is deprecated in Kyverno 1.19).

> **Note:** the Terraform pipeline (with manual approval) is built on Day 8. Until then, Dev is built
> by running Terraform from your computer. From Day 8 onwards, every infrastructure change goes through the pipeline.

### Changes from the design document

| Design | This build | Reason |
|---|---|---|
| Region `us-east-1` | `ap-south-1` | Closer to the team; the code takes the region as a setting |
| SSO for local access | Temporary IAM user access keys | SSO not set up on the account; keys are deleted after the local build (see Step 2) |
| HTTPS with ACM certificate and Route53 record | HTTP on the load balancer's own address | No domain available; HTTPS can be added later with an ACM certificate and two Ingress annotations |
| ArgoCD UI | Port-forward only (ingress prepared, commented) | Nothing exposed; a VPN-based URL can be enabled later |
| IRSA for every workload | IRSA everywhere except Karpenter, which uses EKS Pod Identity | The Karpenter sub-module of the EKS module (v21) supports only Pod Identity; same security result (short-lived, per service account) |
| VPC interface endpoints for ECR, STS, Secrets Manager | Off in Dev (`enable_interface_endpoints = false`); S3 gateway endpoint kept | POC cost (~$3/day); traffic goes through NAT, still TLS. One setting turns them back on |
| Dev runs continuously | Stopped and started on demand (`scripts/platform-stop.sh`, `platform-start.sh`) | POC cost; everything in the cluster is rebuilt from Git |

### Known POC limitations

| # | Limitation | Risk | Fix (when needed) |
|---|---|---|---|
| 1 | **Secrets are not separated per environment.** One ClusterSecretStore and one IAM role (`platform-dev-external-secrets`) can read the dev, staging **and** production secrets. The store's `conditions` check only *which namespace* asks, not *which secret* it asks for, so an ExternalSecret in `dev` that names `platform-dev/my-app/production` would receive production's values. | Low today: only the platform team creates ExternalSecrets, through Git review. Real once developers can create objects in `dev` | One IAM role and one store per environment, each role limited to its own secret (AWS then refuses cross-environment reads). Alternatively the Secrets Store CSI Driver with each app's own IRSA role (see [docs/karpenter-and-external-secrets.md](docs/karpenter-and-external-secrets.md#choosing-how-pods-get-secrets)) |
| 2 | **The account root user is a cluster admin** (`arn:aws:iam::471112815218:root` in `cluster_admin_arns`), added on purpose so the EKS console shows workloads when signed in as root. | Root has unlimited power and cannot be restricted; AWS advises not to use it for daily work | Use the IAM user (already an admin entry) or SSO for the console, then remove the root ARN from `cluster_admin_arns` and apply |

---

## 12. Troubleshooting

| Problem | Fix |
|---|---|
| `command not found` right after installing | Run `source ~/.bashrc`, or open a new terminal |
| A checksum does not match | Do **not** install. Run the script again; if it still fails, the download may be tampered with |
| `Unable to locate credentials` / `Token has expired` | SSO: run `aws sso login`. Access keys: check `echo $AWS_PROFILE` is `task` |
| `aws sts get-caller-identity` shows the wrong account | Check `echo $AWS_PROFILE` |
| Resources appear in the wrong region | Check `echo $AWS_REGION` is `ap-south-1` |
| `gh ... --web` fails: `xdg-open ... not found` | WSL has no browser opener: `echo 'export BROWSER=explorer.exe' >> ~/.bashrc && source ~/.bashrc` |
| `docker` not found in WSL | Turn on WSL integration for Ubuntu in Docker Desktop and restart it |
| GitHub API rate limit during the install script | Wait a few minutes, or run `gh auth login` first and try again |
| Bootstrap fails with `EntityAlreadyExists` on the OIDC provider | The account already has one: redeploy with `CreateOidcProvider=false` |
| `kubectl` hangs or times out | Your public IP changed: `curl -s https://checkip.amazonaws.com`, update `admin_cidrs` in `terraform.tfvars`, plan and apply |
| `terraform apply` says "Saved plan is stale" | Something changed after the plan: run `terraform plan -out=tfplan` again |
| `terraform init` cannot reach the state bucket | Check the profile and region; the bucket name in `backend.tf` must match the bootstrap output |

---

## 13. Cost and Clean-up

This is a POC: Dev runs only while it is being used. Resources cost money **only while they exist**.

### Running cost (ap-south-1, approx.)

| Item | Approx. cost | POC setting |
|---|---|---|
| EKS control plane | ~$2.40 / day | Cannot be paused, only deleted |
| NAT Gateway (1 shared) | ~$1.10 / day + data | Cannot be paused, only deleted |
| VPC interface endpoints (4 × 3 AZs) | ~$3 / day | **Off** (`enable_interface_endpoints = false`) |
| System nodes (2 × t3.medium, On-Demand) | ~$2.20 / day | Kept at 2 on purpose: 1 node saves only ~$1.10/day but Karpenter's 2nd replica cannot schedule (one per node), ArgoCD/Karpenter/ALB controller share one point of failure, and memory is tight. Stop/start is the bigger saving |
| App nodes (Karpenter, Spot, from Day 4) | ~$1–2 / day | Only while app pods need them |
| Load balancer (from Day 5) | ~$0.55 / day | |
| State bucket, bootstrap KMS key | a few cents / day | Kept when stopped |

**Running: about $6–8 per day. Stopped: a few cents per day.**

### Stop and start on demand
Everything inside the cluster comes back from Git, so stopping means deleting the Dev environment and
starting means rebuilding it from code.

```bash
cd ~/workspace/Task/aws-platform
export AWS_PROFILE=task AWS_REGION=ap-south-1

bash scripts/platform-status.sh     # running or stopped? what is costing money? (read-only)
bash scripts/platform-stop.sh       # ~15–20 min, asks twice before deleting anything
bash scripts/platform-start.sh      # ~25–30 min, shows the Terraform plan and asks before applying
```

| Script | What it does, in order |
|---|---|
| `platform-stop.sh` | 1. Checks the AWS account; you type `stop`. 2. Deletes the ArgoCD root app (so nothing is re-created), then the other applications: the load balancer controller removes ALBs for deleted Ingresses, Karpenter removes its nodes. 3. Waits until no ALBs or Karpenter nodes remain (they are not in Terraform and would block the VPC deletion). 4. Uninstalls ArgoCD. 5. `terraform plan -destroy`, you type `yes`, destroy. Removes the EKS log group if EKS re-created it |
| `platform-start.sh` | 1. Checks the account and that your public IP is in `admin_cidrs`. 2. `terraform plan`, you type `yes`, apply. 3. Connects kubectl, waits for the nodes. 4. Installs ArgoCD (Helm), applies `root-app.yaml`, waits until every application is Synced/Healthy |
| `platform-status.sh` | Lists the EKS cluster, nodes, NAT Gateways, interface endpoints, load balancers and Elastic IPs, and says RUNNING or STOPPED |

**Kept when stopped:** bootstrap stack (state bucket, KMS key, GitHub OIDC, pipeline roles), the Terraform
state (now empty for Dev), and everything in Git.

**Lost when stopped, restore after a start:**

| Item | Restore |
|---|---|
| Secret values in Secrets Manager | `aws secretsmanager put-secret-value ...` (the start script prints the command) |
| Images in ECR | Re-run the `my-app` release pipeline (Day 6) or push the image again |
| ArgoCD admin password | New initial password; change it again |
| KMS keys (EKS secrets, app secrets) | New keys are created; the old ones are scheduled for deletion (no charge while pending) |

Dev-only settings that make this possible: `secret_recovery_window_days = 0` (secrets can be re-created at once)
and `ecr_force_delete = true` (the registry can be deleted with images in it). Staging and Production keep the
safe defaults.

### Trade-off of turning off the interface endpoints
Without them, pulls from ECR, IRSA logins (STS) and secret reads go through the NAT Gateway: still encrypted
(TLS), but over the internet path instead of the private AWS network, and billed as NAT data (cents per GB).
For the design's private-endpoint setup set `enable_interface_endpoints = true` (Staging/Production default).

### Budget alert (recommended)
An email when the month's spend passes a limit, in case the environment is forgotten:
```bash
aws budgets create-budget --account-id 471112815218 \
  --budget '{"BudgetName":"aws-platform-poc","BudgetLimit":{"Amount":"50","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"<your-email>"}]}]'
```

### Troubleshooting a stop or start

| Problem | Fix |
|---|---|
| Destroy hangs on the VPC, subnets or a security group | Something created by the cluster still exists: run `platform-status.sh`; delete leftover load balancers (EC2 → Load Balancers) or `k8s-*` security groups, then run the stop script again |
| Start fails: log group `/aws/eks/platform-dev/cluster` already exists | `aws logs delete-log-group --log-group-name /aws/eks/platform-dev/cluster`, then start again |
| Start stops at "Your IP ... is not in admin_cidrs" | Put the printed IP in `terraform.tfvars` and run again |
| An application stays OutOfSync after a start | `kubectl describe application <name> -n argocd`; usually a missing secret value or image |
<-- kyverno e2e 2026-10-13T12:19:15Z -->
