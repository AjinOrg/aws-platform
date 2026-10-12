#!/usr/bin/env bash
# Interactive release: choose staging or production, pick a tested tag from a list, confirm.
# It starts the "release" workflow on GitHub (the same as Actions → release → Run workflow).
#
# Usage:  bash scripts/release.sh            (needs: git, gh logged in; optional: aws to check ECR)
set -euo pipefail

REPO=AjinOrg/aws-platform
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

tag_of() { sed -nE 's/^  tag: "?([^"]+)"?.*/\1/p' "gitops/apps/my-app/values-$1.yaml"; }

echo "Updating from GitHub..."
git pull --quiet --ff-only

echo
PS3="Release to which environment? "
select TO in staging production; do [ -n "${TO:-}" ] && break; done
case "$TO" in staging) FROM=dev ;; production) FROM=staging ;; esac

# Tags that have run in the previous environment, newest first, with the date they were deployed there
mapfile -t ROWS < <(
  git log -p --date=format:'%Y-%m-%d %H:%M' --format='DEPLOYED_AT %ad' -- "gitops/apps/my-app/values-$FROM.yaml" |
  awk '/^DEPLOYED_AT /{d=substr($0,13)} /^\+  tag: /{t=$3; gsub(/"/,"",t); if(!seen[t]++) print t"  (in '"$FROM"' since "d")"}' |
  head -15
)
[ "${#ROWS[@]}" -gt 0 ] || { echo "No tag has run in $FROM yet."; exit 1; }

echo
echo "Now running:  $FROM = $(tag_of "$FROM")   $TO = $(tag_of "$TO")"
echo "Tags that have run in $FROM (newest first):"
PS3="Pick the tag to release to $TO: "
select ROW in "${ROWS[@]}"; do [ -n "${ROW:-}" ] && break; done
TAG="${ROW%% *}"

if command -v aws >/dev/null 2>&1; then
  if aws ecr describe-images --repository-name my-app --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    echo "ECR: $TAG found"
  else
    echo "WARNING: $TAG not found in ECR (or no AWS access); the workflow will check again."
  fi
fi

echo
echo "About to release my-app $TAG to $TO."
[ "$TO" = production ] && echo "The production PR will additionally wait for a Code Owner approval."
read -r -p "Type the environment name ($TO) to confirm: " CONFIRM
[ "$CONFIRM" = "$TO" ] || { echo "Cancelled."; exit 1; }

gh workflow run release.yaml -R "$REPO" -f environment="$TO" -f tag="$TAG"
echo "Started. Following the run (Ctrl+C stops watching, not the release)..."
sleep 5
RUN_ID=$(gh run list -R "$REPO" --workflow release.yaml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" -R "$REPO" || true
gh pr list -R "$REPO" --search "deploy($TO) in:title" --limit 3
