#!/usr/bin/env bash
# Generate test coverage reports for Go (root + api) and frontend (vitest).
# Results are written to output/coverage/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COVERAGE_DIR="$ROOT_DIR/output/coverage"
mkdir -p "$COVERAGE_DIR"

# ── Minimum thresholds (percentage) ────────────────────────────────
GO_MIN_COVERAGE="${GO_MIN_COVERAGE:-0}"
FRONTEND_MIN_COVERAGE="${FRONTEND_MIN_COVERAGE:-0}"

# ── Go coverage (root module) ─────────────────────────────────────
echo "=== Go coverage (root) ==="
ROOT_PACKAGES="$(go list ./... | grep -v '^privatedeploy/tmp$')"
go test -coverprofile="$COVERAGE_DIR/go-root.out" -covermode=atomic $ROOT_PACKAGES
GO_ROOT_LINE="$(go tool cover -func="$COVERAGE_DIR/go-root.out" | tail -1)"
GO_ROOT_PCT="$(echo "$GO_ROOT_LINE" | awk '{print $NF}' | tr -d '%')"
echo "$GO_ROOT_LINE"
go tool cover -html="$COVERAGE_DIR/go-root.out" -o "$COVERAGE_DIR/go-root.html"

# ── Go coverage (api module) ──────────────────────────────────────
echo ""
echo "=== Go coverage (api) ==="
(
  cd api
  go test -coverprofile="$COVERAGE_DIR/go-api.out" -covermode=atomic ./...
)
GO_API_LINE="$(cd api && go tool cover -func="$COVERAGE_DIR/go-api.out" | tail -1)"
GO_API_PCT="$(echo "$GO_API_LINE" | awk '{print $NF}' | tr -d '%')"
echo "$GO_API_LINE"
(cd api && go tool cover -html="$COVERAGE_DIR/go-api.out" -o "$COVERAGE_DIR/go-api.html")

# ── Frontend coverage ─────────────────────────────────────────────
echo ""
echo "=== Frontend coverage (vitest) ==="
(
  cd frontend
  pnpm run test:coverage
)

# Parse frontend summary
FRONTEND_TOTAL="0"
FRONTEND_SUMMARY="$ROOT_DIR/frontend/coverage/coverage-summary.json"
if [ -f "$FRONTEND_SUMMARY" ]; then
  FRONTEND_TOTAL="$(python3 -c "
import json
d = json.load(open('$FRONTEND_SUMMARY'))
print(f\"{d['total']['lines']['pct']:.1f}\")
" 2>/dev/null || echo "0")"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          Coverage Summary                ║"
echo "╠══════════════════════════════════════════╣"
printf "║  Go (root module):   %6s%%             ║\n" "$GO_ROOT_PCT"
printf "║  Go (api module):    %6s%%             ║\n" "$GO_API_PCT"
printf "║  Frontend (lines):   %6s%%             ║\n" "$FRONTEND_TOTAL"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "HTML reports:"
echo "  Go root: $COVERAGE_DIR/go-root.html"
echo "  Go api:  $COVERAGE_DIR/go-api.html"
echo "  Frontend: $ROOT_DIR/frontend/coverage/index.html"

# ── Threshold check ───────────────────────────────────────────────
FAILED=0

check_threshold() {
  local name="$1" actual="$2" min="$3"
  if [ "$min" -gt 0 ] 2>/dev/null; then
    local actual_int="${actual%%.*}"
    if [ "$actual_int" -lt "$min" ]; then
      echo "FAIL: $name coverage ${actual}% < minimum ${min}%"
      FAILED=1
    fi
  fi
}

check_threshold "Go (root)" "$GO_ROOT_PCT" "$GO_MIN_COVERAGE"
check_threshold "Go (api)" "$GO_API_PCT" "$GO_MIN_COVERAGE"
check_threshold "Frontend" "$FRONTEND_TOTAL" "$FRONTEND_MIN_COVERAGE"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
