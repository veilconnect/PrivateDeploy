#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="${ROOT_DIR}/patches/wails-v2.12.0-webkit-construct-policy.patch"
WAILS_VERSION="v2.12.0"

if (( $# == 0 )); then
  echo "usage: $0 command [args...]" >&2
  exit 2
fi
command -v go >/dev/null 2>&1 || { echo "go is required" >&2; exit 1; }
command -v patch >/dev/null 2>&1 || { echo "patch is required" >&2; exit 1; }
[[ -f "${PATCH_FILE}" ]] || { echo "missing Wails patch: ${PATCH_FILE}" >&2; exit 1; }

declared_version="$(cd "${ROOT_DIR}" && go list -m -f '{{.Version}}' github.com/wailsapp/wails/v2)"
[[ "${declared_version}" == "${WAILS_VERSION}" ]] || {
  echo "Wails patch targets ${WAILS_VERSION}, found ${declared_version}" >&2
  exit 1
}

module_dir="$(cd "${ROOT_DIR}" && go list -m -f '{{.Dir}}' github.com/wailsapp/wails/v2)"
[[ -d "${module_dir}" ]] || { echo "Wails module directory is unavailable" >&2; exit 1; }

# GOFLAGS is whitespace-delimited and has no portable quoting for a -modfile
# path containing spaces. Linux always provides /tmp, so keep this generated
# path independent of a caller-controlled TMPDIR.
patch_root="$(mktemp -d /tmp/privatedeploy-wails-patch.XXXXXX)"
cleanup() {
  rm -rf -- "${patch_root}"
}
trap cleanup EXIT

cp -a -- "${module_dir}" "${patch_root}/wails"
chmod -R u+w "${patch_root}/wails"
patch -s -d "${patch_root}/wails" -p1 <"${PATCH_FILE}"

cp -- "${ROOT_DIR}/go.mod" "${patch_root}/privatedeploy.mod"
cp -- "${ROOT_DIR}/go.sum" "${patch_root}/privatedeploy.sum"
go mod edit -modfile="${patch_root}/privatedeploy.mod" \
  -replace="github.com/wailsapp/wails/v2=${patch_root}/wails"

if [[ -n "${GOFLAGS:-}" ]]; then
  export GOFLAGS="${GOFLAGS} -modfile=${patch_root}/privatedeploy.mod"
else
  export GOFLAGS="-modfile=${patch_root}/privatedeploy.mod"
fi

"$@"
