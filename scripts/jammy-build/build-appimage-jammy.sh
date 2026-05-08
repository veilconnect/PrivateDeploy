#!/bin/bash
# Wrapper: rebuild the Docker image (if needed), then run the in-container
# build (binary + frontend) and the in-container AppImage packaging step.
#
#   bash scripts/jammy-build/build-appimage-jammy.sh 2.0.0
# Reuses caches with build-linux-packages-jammy.sh.

set -euo pipefail

VERSION="${1:-2.0.0}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.12.12}"
SINGBOX_ARCHIVE_PATH="${SINGBOX_ARCHIVE_PATH:-}"
IMAGE_TAG="${IMAGE_TAG:-privatedeploy-jammy-build:latest}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCKERFILE="${REPO_ROOT}/scripts/jammy-build/Dockerfile"

echo "==> Building Docker image ${IMAGE_TAG}"
docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE}" "${REPO_ROOT}/scripts/jammy-build"

GO_CACHE_VOL=privatedeploy-jammy-gocache
PNPM_CACHE_VOL=privatedeploy-jammy-pnpmcache
docker volume create "${GO_CACHE_VOL}" >/dev/null
docker volume create "${PNPM_CACHE_VOL}" >/dev/null

DOCKER_ENV_ARGS=()
DOCKER_VOL_ARGS=()
if [[ -n "${SINGBOX_ARCHIVE_PATH}" ]]; then
    [[ -f "${SINGBOX_ARCHIVE_PATH}" ]] || { echo "missing: ${SINGBOX_ARCHIVE_PATH}"; exit 1; }
    DOCKER_VOL_ARGS+=(-v "${SINGBOX_ARCHIVE_PATH}:/singbox-archive.tar.gz:ro")
    DOCKER_ENV_ARGS+=(-e "SINGBOX_ARCHIVE_PATH=/singbox-archive.tar.gz")
fi

echo "==> Running compile + AppImage packaging inside container"
docker run --rm \
    -v "${REPO_ROOT}:/repo" \
    -v "${GO_CACHE_VOL}:/go/pkg/mod" \
    -v "${PNPM_CACHE_VOL}:/root/.local/share/pnpm/store" \
    "${DOCKER_VOL_ARGS[@]}" \
    -e "VERSION=${VERSION}" \
    -e "SINGBOX_VERSION=${SINGBOX_VERSION}" \
    "${DOCKER_ENV_ARGS[@]}" \
    "${IMAGE_TAG}" \
    bash -c '
        set -euo pipefail
        SKIP_DEB_PACKAGING=1 bash /repo/scripts/jammy-build/in-container-build.sh
        bash /repo/scripts/jammy-build/in-container-appimage.sh
    '

echo "==> AppImage in:"
ls -lh "${REPO_ROOT}/build/bin/jammy/"*.AppImage 2>/dev/null || true
