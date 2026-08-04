#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "secret scan failed: ripgrep (rg) is required" >&2
  exit 2
fi

patterns=(
  'cfut_[A-Za-z0-9_-]+'
  'github_pat_[A-Za-z0-9_]+'
  'ghp_[A-Za-z0-9]{36,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----'
  'CLOUDFLARE_API_TOKEN[[:space:]]*=[[:space:]]*['"'"'"'"'"']?[A-Za-z0-9_-]{20,}'
)

# Never allow release credential containers/configuration to be tracked, even
# if a developer force-adds a path covered by .gitignore. `rg` follows ignore
# rules, but `git ls-files` is the authoritative release input set.
tracked_sensitive_re='(^|/)(key\.properties|ExportOptions\.plist|.*\.(jks|keystore|p12|pfx|mobileprovision))$'
tracked_sensitive="$(git ls-files | grep -E "$tracked_sensitive_re" || true)"
if [[ -n "$tracked_sensitive" ]]; then
  echo "secret scan failed: tracked signing credential/configuration file(s):" >&2
  printf '%s\n' "$tracked_sensitive" >&2
  exit 1
fi

# Scan tracked working-tree files separately. Unlike the broad rg pass below,
# git grep includes a force-added file even when an ignore rule matches it.
git_grep_args=(--line-number -I --extended-regexp)
for pattern in "${patterns[@]}"; do
  git_grep_args+=(-e "$pattern")
done
git_paths=(
  -- .
  ':(exclude)scripts/secret_scan.sh'
  ':(exclude).gitleaks.toml'
  ':(exclude)frontend/src/views/CloudView/components/SSHConfigForm.vue'
  ':(exclude)frontend/src/views/WizardView/components/StepCredentials.vue'
)
if git grep "${git_grep_args[@]}" "${git_paths[@]}"; then
  echo "secret scan failed: possible credential material found in tracked files" >&2
  exit 1
fi

args=(
  --hidden
  --line-number
  --no-heading
  --glob '!.git/**'
  --glob '!node_modules/**'
  --glob '!frontend/node_modules/**'
  --glob '!mobile/build/**'
  --glob '!output/**'
  --glob '!website/assets/*.png'
  --glob '!scripts/secret_scan.sh'
  --glob '!.gitleaks.toml'
  --glob '!frontend/src/views/CloudView/components/SSHConfigForm.vue'
  --glob '!frontend/src/views/WizardView/components/StepCredentials.vue'
)

for pattern in "${patterns[@]}"; do
  args+=(-e "$pattern")
done

if rg "${args[@]}" .; then
  echo "secret scan failed: possible credential material found" >&2
  exit 1
fi

echo "Secret scan OK"
