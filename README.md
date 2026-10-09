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
11. [Build Progress (Days 1 to 6)](#11-build-progress-days-1-to-6)
12. [Troubleshooting](#12-troubleshooting)
13. [Cost and Clean-up](#13-cost-and-clean-up)

---

## 1. What Will Live Here

Folders are added step by step as the build progresses.

| Folder | What it holds | Added on |
|---|---|---|
| `scripts/` | Helper scripts (tool installer) | Day 1 |
| `bootstrap/` | One-time CloudFormation template: Terraform state bucket, KMS key, GitHub login trust and pipeline roles | Day 1 |
| `terraform/modules/` | Reusable building blocks: `vpc`, `eks`, `ecr`, `iam`, `secrets` | Days 1–2 |
| `terraform/environments/` | Settings for each environment: `dev`, `staging`, `production` | Days 1–3 |
| `gitops/` | What ArgoCD installs: platform add-ons and the app's settings per environment | Days 3–5 |
| `helm/my-app/` | How the application is packaged for Kubernetes | Day 5 |
| `policies/kyverno/` | Security rules the cluster enforces | Day 8 |
| `monitoring/` | Alert rules and dashboards | Day 9 |
| `demo/` | Deliberately bad files for the demo, and the load test | Day 8 |
| `.github/workflows/` | Pipelines: platform checks and Terraform | Days 6, 8 |
| `docs/` | Architecture, decisions, trade-offs, runbook | Day 10 |

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
| GitHub owner | `AjinOrg` (organization, created under the personal account `AjinUrolime`) | Repositories: `AjinOrg/aws-platform`, `AjinOrg/my-app` |
| Bootstrap stack | `aws-platform-bootstrap` | Termination protection on |
| Terraform state bucket | `aws-platform-tfstate-471112815218` | State path per environment: `aws-platform/<env>/terraform.tfstate` |
| State KMS key | `alias/aws-platform-tfstate` | |
| Dev VPC CIDR | `10.0.0.0/16` | Staging `10.1.0.0/16`, Production `10.2.0.0/16` |
| Dev cluster name | `platform-dev` | |

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
  --capabilities CAPABILITY_NAMED_IAM --no-execute-changeset
aws cloudformation list-change-sets --stack-name aws-platform-bootstrap --query "Summaries[0].ChangeSetName" --output text
aws cloudformation describe-change-set --stack-name aws-platform-bootstrap --change-set-name <name-from-above> \
  --query "Changes[].ResourceChange.[Action,LogicalResourceId,Replacement]" --output table
# expect: Modify EcrPushRole / TerraformPlanRole / TerraformApplyRole, Replacement False

# Apply
aws cloudformation execute-change-set --stack-name aws-platform-bootstrap --change-set-name <name-from-above>
aws cloudformation wait stack-update-complete --stack-name aws-platform-bootstrap

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

| Role | Trusted only for | Can do |
|---|---|---|
| `aws-platform-ecr-push` | `AjinOrg/my-app`, `main` branch | Push and read images in the `my-app` ECR repository; nothing else |
| `aws-platform-terraform-plan` | `AjinOrg/aws-platform`, pull requests and `main` | Read-only on the account (`ReadOnlyAccess`) plus the state files; cannot change infrastructure |
| `aws-platform-terraform-apply` | `AjinOrg/aws-platform`, GitHub Environment `terraform-apply` | Administrator; reachable only by a job a reviewer has approved |

Until Day 8 these roles are unused: Terraform runs from your computer with your own credentials.

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

## 11. Build Progress (Days 1 to 6)

Tick each item as it is done.

**Day 1: Setup, state backend and network**
- [x] Tools installed (Step 1)
- [x] AWS access working (Step 2: profile `task`, temporary IAM user keys)
- [x] GitHub connected (Step 3: `gh` logged in as `AjinUrolime`, organization `AjinOrg` granted)
- [x] `aws-platform` repository created on GitHub (`AjinOrg/aws-platform`, public)
- [ ] `my-app` repository created on GitHub
- [x] CloudFormation bootstrap deployed and verified (state bucket, KMS key, GitHub OIDC, pipeline roles)
- [x] VPC created with Terraform (3 AZs, NAT, endpoints, flow logs)

**Day 2: EKS cluster and supporting AWS resources**
- [x] EKS cluster `platform-dev` (1.36) and system node group (2 × t3.medium)
- [x] ECR repository, Secrets Manager secrets, IRSA roles (one apply with the VPC: 86 resources)

**Day 3: Dev environment and GitOps**
- [x] `kubectl` connected to the Dev cluster
- [ ] ArgoCD installed, app-of-apps structure in place
- [ ] AWS Load Balancer Controller, certificate, DNS record and HTTPS ingress

**Day 4: Platform add-ons**
- [ ] Karpenter
- [ ] External Secrets Operator and ClusterSecretStore
- [ ] Default-deny network policies

**Day 5: Application deployment**
- [ ] Sample app and Dockerfile (non-root, health endpoints)
- [ ] Helm chart
- [ ] App deployed to the dev, staging and production namespaces

**Day 6: CI pipelines**
- [ ] `my-app` pull request checks: Gitleaks, lint, tests, OWASP, Trivy
- [ ] `aws-platform` checks: Gitleaks, Helm lint, kubeconform, Checkov
- [ ] Kyverno CLI check in `my-app`

> **Note:** the Terraform pipeline (with manual approval) is built on Day 8. Until then, Dev is built
> by running Terraform from your computer. From Day 8 onwards, every infrastructure change goes through the pipeline.

### Changes from the design document

| Design | This build | Reason |
|---|---|---|
| Region `us-east-1` | `ap-south-1` | Closer to the team; the code takes the region as a setting |
| SSO for local access | Temporary IAM user access keys | SSO not set up on the account; keys are deleted after the local build (see Step 2) |

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

Resources cost money **only while they exist**. Rough Dev cost while running (ap-south-1):

| Item | Approx. cost |
|---|---|
| EKS control plane | ~$2.40 / day |
| NAT Gateway (1 shared) | ~$1.10 / day + data |
| VPC interface endpoints (4 × 3 AZs) | ~$3 / day |
| System nodes (2 × t3.medium, On-Demand) | ~$2.20 / day |
| App nodes (Karpenter, Spot, from Day 4) | ~$1–2 / day |
| Load balancer | ~$0.55 / day |
| State bucket, KMS key | a few cents / day (KMS key ~$1 / month) |

When you are not using Dev for a while, it can be destroyed with Terraform and rebuilt later from the same
code. The bootstrap stack (state bucket) is kept, because it is protected and costs almost nothing.
Teardown steps are added once the environment exists.
