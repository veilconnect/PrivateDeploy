#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash scripts/check_versions.sh

COVERAGE_DIR="$ROOT_DIR/output/coverage"
mkdir -p "$COVERAGE_DIR"

# The root Go package embeds frontend/dist, which is intentionally gitignored.
# Build the static assets first so a clean checkout can run the Go tests.
(
  cd frontend
  pnpm run build-only
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
  pnpm run type-check
  pnpm run lint:ci
  pnpm run test:coverage
)

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
echo "  Go (root): $GO_ROOT_PCT"
echo "  Go (api):  $GO_API_PCT"
echo "  Frontend:  $FRONTEND_TOTAL"
echo "=================================="
