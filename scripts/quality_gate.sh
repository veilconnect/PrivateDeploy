#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Corepack may try to download the packageManager-pinned pnpm even when this
# checkout already has a complete node_modules tree. Prefer those verified
# local tools for an offline gate; clean CI checkouts still use pnpm after the
# workflow's install/setup step.
FRONTEND_RUNNER=(pnpm run)
if [[ -x "${ROOT_DIR}/frontend/node_modules/.bin/vite" &&
      -x "${ROOT_DIR}/frontend/node_modules/.bin/vue-tsc" &&
      -x "${ROOT_DIR}/frontend/node_modules/.bin/eslint" &&
      -x "${ROOT_DIR}/frontend/node_modules/.bin/vitest" ]]; then
  FRONTEND_RUNNER=(npm run)
fi

bash scripts/check_versions.sh
bash scripts/tests/jammy_toolchain_test.sh
bash scripts/tests/install_local_linux_test.sh

# Jammy release builds intentionally use -skipbindings, so stale generated
# Wails modules would compile but fail only when the renderer calls a new API.
# Keep the recovery/ready handshake surface tied to the Go bridge at the gate.
for symbol in CancelCloudOperation GetCloudOperationStatus ListPendingCloudOperations SignalFrontendReady; do
  rg -q "^export function ${symbol}\\(" frontend/src/bridge/wailsjs/go/bridge/App.js || {
    echo "missing generated Wails JS binding: ${symbol}" >&2
    exit 1
  }
  rg -q "^export function ${symbol}\\(" frontend/src/bridge/wailsjs/go/bridge/App.d.ts || {
    echo "missing generated Wails TypeScript binding: ${symbol}" >&2
    exit 1
  }
done

COVERAGE_DIR="$ROOT_DIR/output/coverage"
mkdir -p "$COVERAGE_DIR"

# The root Go package embeds frontend/dist, which is intentionally gitignored.
# Build the static assets first so a clean checkout can run the Go tests.
(
  cd frontend
  "${FRONTEND_RUNNER[@]}" build-only
)

# ── Go tests with coverage (root) ─────────────────────────────────
ROOT_PACKAGES="$(go list ./... | grep -Ev '^privatedeploy/tmp($|/)')"
go test -coverprofile="$COVERAGE_DIR/go-root.out" -covermode=atomic $ROOT_PACKAGES
echo "--- Go root coverage ---"
go tool cover -func="$COVERAGE_DIR/go-root.out" | tail -1

# ── Go tests with coverage (api) ──────────────────────────────────
(
  cd api
  go test -coverprofile="$COVERAGE_DIR/go-api.out" -covermode=atomic ./...
  echo "--- Go api coverage ---"
  go tool cover -func="$COVERAGE_DIR/go-api.out" | tail -1
)

# ── Frontend checks ───────────────────────────────────────────────
(
  cd frontend
  "${FRONTEND_RUNNER[@]}" type-check
  "${FRONTEND_RUNNER[@]}" lint:ci
  "${FRONTEND_RUNNER[@]}" test:coverage
)

# ── CDN front keep-alive smoke (M1 worker) ───────────────────────
# Hits relay-f2cfd6.example.test via DoH + TLS + WS-with-wrong-secret to
# confirm the standby CDN-acceleration path doesn't silently rot between
# releases. The tests t.Skip when DoH itself can't resolve (offline dev
# box), so this stays green when there's no network — only fails when the
# network IS up but the Worker / custom domain has gone away. Warning-
# only, doesn't block the gate, because Cloudflare hiccups shouldn't
# stop a local quality run; release validation should still eyeball this
# line. Set PRIVATEDEPLOY_SKIP_CDN_SMOKE=1 to bypass entirely.
CDN_SMOKE_STATUS="skipped"
if [ "${PRIVATEDEPLOY_SKIP_CDN_SMOKE:-0}" != "1" ]; then
  echo ""
  echo "── CDN front smoke (M1 worker keep-alive) ──"
  if go test -tags=smoke -timeout=60s -count=1 -run TestProbeSmoke ./bridge/cdn/...; then
    CDN_SMOKE_STATUS="passed"
  else
    CDN_SMOKE_STATUS="FAILED"
    echo "⚠ CDN front smoke FAILED — M1 worker may be down or"
    echo "  relay-f2cfd6.example.test config drifted. See"
    echo "  docs/cdn-acceleration/SMOKE-TEST.md for manual recovery."
  fi
fi

# ── Coverage summary ──────────────────────────────────────────────
GO_ROOT_PCT="$(go tool cover -func="$COVERAGE_DIR/go-root.out" | tail -1 | awk '{print $NF}')"
GO_API_PCT="$(cd api && go tool cover -func="$COVERAGE_DIR/go-api.out" | tail -1 | awk '{print $NF}')"

FRONTEND_SUMMARY="$ROOT_DIR/frontend/coverage/coverage-summary.json"
if [ -f "$FRONTEND_SUMMARY" ]; then
  FRONTEND_TOTAL="$(python3 -c "
import json
d = json.load(open('$FRONTEND_SUMMARY'))
print(f\"{d['total']['lines']['pct']:.1f}%\")
" 2>/dev/null || echo "N/A")"
else
  FRONTEND_TOTAL="N/A"
fi

echo ""
echo "======== Coverage Summary ========"
echo "  Go (root):       $GO_ROOT_PCT"
echo "  Go (api):        $GO_API_PCT"
echo "  Frontend:        $FRONTEND_TOTAL"
echo "  CDN front smoke: $CDN_SMOKE_STATUS"
echo "=================================="
