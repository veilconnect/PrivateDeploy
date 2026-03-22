#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ROOT_PACKAGES="$(go list ./... | grep -v '^privatedeploy/tmp$')"
go test $ROOT_PACKAGES

(
  cd api
  go test ./...
)

(
  cd frontend
  pnpm run type-check
  pnpm run lint:ci
)
