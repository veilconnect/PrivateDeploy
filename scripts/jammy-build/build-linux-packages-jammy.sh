#!/bin/bash
# Linux packages built against WebKitGTK 4.0 (libsoup2) in Ubuntu 22.04 jammy.
# Workaround for the libwebkit2gtk-4.1 2.52.x crash on Ubuntu 24.04 noble.
#
# Run from repo root via:
#   bash scripts/jammy-build/build-linux-packages-jammy.sh 2.0.0
# This script wraps Docker; it does NOT run inside the container itself.

set -euo pipefail

VERSION="${1:-2.0.0}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"
SINGBOX_ARCHIVE_PATH="${SINGBOX_ARCHIVE_PATH:-}"
IMAGE_TAG="${IMAGE_TAG:-privatedeploy-jammy-build:latest}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCKERFILE="${REPO_ROOT}/scripts/jammy-build/Dockerfile"

if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "ERROR: Dockerfile not found at ${DOCKERFILE}" >&2
    exit 1
fi

echo "==> Building Docker image ${IMAGE_TAG}"
docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE}" "${REPO_ROOT}/scripts/jammy-build"

# Mount go and pnpm caches so repeat builds are fast
GO_CACHE_VOL=privatedeploy-jammy-gocache
PNPM_CACHE_VOL=privatedeploy-jammy-pnpmcache
docker volume create "${GO_CACHE_VOL}" >/dev/null
docker volume create "${PNPM_CACHE_VOL}" >/dev/null

# Copy host sing-box archive into the build context (if provided) so the
# in-container script can use SINGBOX_ARCHIVE_PATH without network access.
DOCKER_ENV_ARGS=()
DOCKER_VOL_ARGS=()
if [[ -n "${SINGBOX_ARCHIVE_PATH}" ]]; then
    if [[ ! -f "${SINGBOX_ARCHIVE_PATH}" ]]; then
        echo "ERROR: SINGBOX_ARCHIVE_PATH does not exist: ${SINGBOX_ARCHIVE_PATH}" >&2
        exit 1
    fi
    DOCKER_VOL_ARGS+=(-v "${SINGBOX_ARCHIVE_PATH}:/singbox-archive.tar.gz:ro")
    DOCKER_ENV_ARGS+=(-e "SINGBOX_ARCHIVE_PATH=/singbox-archive.tar.gz")
fi

echo "==> Running build inside container"
docker run --rm \
    -v "${REPO_ROOT}:/repo" \
    -v "${GO_CACHE_VOL}:/go/pkg/mod" \
    -v "${PNPM_CACHE_VOL}:/root/.local/share/pnpm/store" \
    "${DOCKER_VOL_ARGS[@]}" \
    -e "VERSION=${VERSION}" \
    -e "SINGBOX_VERSION=${SINGBOX_VERSION}" \
    "${DOCKER_ENV_ARGS[@]}" \
    "${IMAGE_TAG}" \
    bash /repo/scripts/jammy-build/in-container-build.sh

echo "==> Build complete:"
ls -la "${REPO_ROOT}/build/bin/"privatedeploy_*.deb \
       "${REPO_ROOT}/build/bin/"privatedeploy-*.rpm 2>/dev/null || true
