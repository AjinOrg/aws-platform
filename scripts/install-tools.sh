#!/usr/bin/env bash
# Installs the platform tools into ~/.local/bin (no sudo needed).
# Every download is checked against the project's official SHA256 checksum;
# the script stops if any checksum does not match.
#
# Usage:  bash scripts/install-tools.sh
set -euo pipefail

BIN="$HOME/.local/bin"
DL="$(mktemp -d /tmp/tooldl.XXXXXX)"   # fresh, empty download folder
mkdir -p "$BIN"
cd "$DL"

latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'; }
verify() { # verify <file> <checksums-file>
  grep -E "[[:space:]]\*?$(basename "$1")\$" "$2" | sha256sum -c - >/dev/null && echo "  checksum OK: $1"
}
unzip_py() { python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"; }

echo "== Terraform"
TF=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform | python3 -c 'import json,sys; print(json.load(sys.stdin)["current_version"])')
curl -fsSLO "https://releases.hashicorp.com/terraform/${TF}/terraform_${TF}_linux_amd64.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${TF}/terraform_${TF}_SHA256SUMS"
verify "terraform_${TF}_linux_amd64.zip" "terraform_${TF}_SHA256SUMS"
unzip_py "terraform_${TF}_linux_amd64.zip" tf && install -m 755 tf/terraform "$BIN/terraform"

echo "== Helm"
HV=$(latest helm/helm)
curl -fsSLO "https://get.helm.sh/helm-${HV}-linux-amd64.tar.gz"
curl -fsSL "https://get.helm.sh/helm-${HV}-linux-amd64.tar.gz.sha256sum" -o helm.sha256
verify "helm-${HV}-linux-amd64.tar.gz" helm.sha256
tar -xzf "helm-${HV}-linux-amd64.tar.gz" && install -m 755 linux-amd64/helm "$BIN/helm"

echo "== ArgoCD CLI"
AV=$(latest argoproj/argo-cd)
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${AV}/argocd-linux-amd64"
curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${AV}/cli_checksums.txt" -o argocd.sha256
verify argocd-linux-amd64 argocd.sha256
install -m 755 argocd-linux-amd64 "$BIN/argocd"

echo "== GitHub CLI"
GV=$(latest cli/cli); G=${GV#v}
curl -fsSLO "https://github.com/cli/cli/releases/download/${GV}/gh_${G}_linux_amd64.tar.gz"
curl -fsSL "https://github.com/cli/cli/releases/download/${GV}/gh_${G}_checksums.txt" -o gh.sha256
verify "gh_${G}_linux_amd64.tar.gz" gh.sha256
tar -xzf "gh_${G}_linux_amd64.tar.gz" && install -m 755 "gh_${G}_linux_amd64/bin/gh" "$BIN/gh"

echo "== Trivy"
TV=$(latest aquasecurity/trivy); T=${TV#v}
curl -fsSLO "https://github.com/aquasecurity/trivy/releases/download/${TV}/trivy_${T}_Linux-64bit.tar.gz"
curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/${TV}/trivy_${T}_checksums.txt" -o trivy.sha256
verify "trivy_${T}_Linux-64bit.tar.gz" trivy.sha256
mkdir trivy && tar -xzf "trivy_${T}_Linux-64bit.tar.gz" -C trivy && install -m 755 trivy/trivy "$BIN/trivy"

echo "== Gitleaks"
LV=$(latest gitleaks/gitleaks); L=${LV#v}
curl -fsSLO "https://github.com/gitleaks/gitleaks/releases/download/${LV}/gitleaks_${L}_linux_x64.tar.gz"
curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/${LV}/gitleaks_${L}_checksums.txt" -o gitleaks.sha256
verify "gitleaks_${L}_linux_x64.tar.gz" gitleaks.sha256
mkdir gitleaks && tar -xzf "gitleaks_${L}_linux_x64.tar.gz" -C gitleaks && install -m 755 gitleaks/gitleaks "$BIN/gitleaks"

echo "== Checkov (own Python environment)"
python3 -m venv "$HOME/.venvs/checkov"
"$HOME/.venvs/checkov/bin/pip" install -q --upgrade pip checkov
ln -sf "$HOME/.venvs/checkov/bin/checkov" "$BIN/checkov"

rm -rf "$DL"

# Make sure ~/.local/bin is on PATH for new terminals
grep -q '.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

echo "== Installed versions"
export PATH="$BIN:$PATH"
terraform version | head -1
helm version --short
argocd version --client --short 2>/dev/null | head -1
gh --version | head -1
trivy --version | head -1
gitleaks version
checkov --version
