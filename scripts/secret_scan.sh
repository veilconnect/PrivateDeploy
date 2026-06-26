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
