#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
IMAGE_TAG="${IMAGE_TAG:-privatedeploy/gui-smoke:local}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-${ROOT_DIR}/docker/gui-smoke/Dockerfile}"
APP_BIN="${APP_BIN:-${ROOT_DIR}/build/bin/PrivateDeploy}"
SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-${ROOT_DIR}/build/bin/data}"
SOURCE_SECRET_DIR="${SOURCE_SECRET_DIR:-${ROOT_DIR}/build/bin/secrets}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${ROOT_DIR}/output/gui-smoke}"
RUN_ID="${RUN_ID:-local-gui-container-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
APP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/pd-local-gui-container-XXXXXX")"
APP_WINDOW_TITLE="${APP_WINDOW_TITLE:-PrivateDeployGuiSmoke}"
SCALES="${SCALES:-100 125 150}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HOST_USER="${HOST_USER:-$(id -un 2>/dev/null || echo user)}"
CONTAINER_GUI_SMOKE_USE_HOST_DISPLAY="${CONTAINER_GUI_SMOKE_USE_HOST_DISPLAY:-0}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in "${CONTAINER_ENGINE}" cp chmod mkdir date; do
  require_cmd "${cmd}"
done

x11_socket_for_display() {
  local display_value="$1"
  local normalized="${display_value#localhost:}"
  normalized="${normalized#127.0.0.1:}"
  if [[ "${normalized}" != :* ]]; then
    return 1
  fi
  normalized="${normalized#:}"
  normalized="${normalized%%.*}"
  if [[ -z "${normalized}" ]]; then
    return 1
  fi
  printf '/tmp/.X11-unix/X%s\n' "${normalized}"
}

host_display_ready() {
  [[ "${CONTAINER_GUI_SMOKE_USE_HOST_DISPLAY}" == "1" ]] || return 1
  [[ -n "${DISPLAY:-}" ]] || return 1

  local socket_path
  socket_path="$(x11_socket_for_display "${DISPLAY}")" || return 1
  [[ -S "${socket_path}" ]] || return 1

  local authority="${XAUTHORITY:-${HOME}/.Xauthority}"
  [[ -f "${authority}" ]] || return 1

  printf '%s\n%s\n' "${DISPLAY}" "${authority}"
}

if [[ ! -x "${APP_BIN}" ]]; then
  echo "App binary not found or not executable: ${APP_BIN}" >&2
  exit 1
fi

mkdir -p "${RUN_DIR}" "${APP_BASE}/data" "${APP_BASE}/secrets"

snapshot_proxy() {
  local target="$1"
  if command -v gsettings >/dev/null 2>&1; then
    {
      echo "mode=$(gsettings get org.gnome.system.proxy mode)"
      echo "http_host=$(gsettings get org.gnome.system.proxy.http host)"
      echo "http_port=$(gsettings get org.gnome.system.proxy.http port)"
      echo "socks_host=$(gsettings get org.gnome.system.proxy.socks host)"
      echo "socks_port=$(gsettings get org.gnome.system.proxy.socks port)"
    } > "${target}"
  else
    echo "gsettings-unavailable" > "${target}"
  fi
}

cleanup() {
  snapshot_proxy "${RUN_DIR}/proxy.after"
  if [[ "${KEEP_APP_BASE:-0}" != "1" ]]; then
    rm -rf "${APP_BASE}"
  else
    echo "Kept app base at: ${APP_BASE}" >&2
  fi
}
trap cleanup EXIT

snapshot_proxy "${RUN_DIR}/proxy.before"

cp "${APP_BIN}" "${APP_BASE}/${APP_WINDOW_TITLE}"
chmod +x "${APP_BASE}/${APP_WINDOW_TITLE}"

if [[ -d "${SOURCE_DATA_DIR}" ]]; then
  cp -a "${SOURCE_DATA_DIR}/." "${APP_BASE}/data/"
fi

if [[ -d "${SOURCE_SECRET_DIR}" ]]; then
  cp -a "${SOURCE_SECRET_DIR}/." "${APP_BASE}/secrets/"
fi

cat > "${APP_BASE}/data/user.yaml" <<'YAML'
width: 1280
height: 840
webviewGpuPolicy: 1
autoSetSystemProxy: false
systemProxyPolicyInitialized: true
systemProxyManaged: false
systemProxyBackup: ""
pages:
  - Workbench
YAML

if [[ "${REBUILD_IMAGE:-0}" == "1" ]] || ! "${CONTAINER_ENGINE}" image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  "${CONTAINER_ENGINE}" build \
    -t "${IMAGE_TAG}" \
    -f "${DOCKERFILE_PATH}" \
    "${ROOT_DIR}/docker/gui-smoke"
fi

echo "Artifacts: ${RUN_DIR}"
echo "App base:   ${APP_BASE}"

HOST_DISPLAY_ENV=""
HOST_XAUTHORITY_ENV=""
if host_display_info="$(host_display_ready)"; then
  HOST_DISPLAY_ENV="$(printf '%s' "${host_display_info}" | sed -n '1p')"
  HOST_XAUTHORITY_ENV="$(printf '%s' "${host_display_info}" | sed -n '2p')"
  echo "Display:    host ${HOST_DISPLAY_ENV}"
else
  echo "Display:    Xvfb fallback"
fi

run_status=0
docker_args=(
  run
  --rm
  --user "${HOST_UID}:${HOST_GID}"
  --shm-size=1g
  -e APP_BASE=/work/appbase
  -e APP_BIN="/work/appbase/${APP_WINDOW_TITLE}"
  -e APP_TITLE="${APP_WINDOW_TITLE}"
  -e HOST_UID="${HOST_UID}"
  -e HOST_GID="${HOST_GID}"
  -e HOST_USER="${HOST_USER}"
  -e OUTPUT_DIR=/work/output
  -e SCALES="${SCALES}"
  -v /etc/passwd:/etc/passwd:ro
  -v /etc/group:/etc/group:ro
  -v "${APP_BASE}:/work/appbase"
  -v "${RUN_DIR}:/work/output"
  -v "${ROOT_DIR}:/workspace:ro"
)

if [[ -n "${HOST_DISPLAY_ENV}" && -n "${HOST_XAUTHORITY_ENV}" ]]; then
  docker_args+=(
    -e GUI_SMOKE_USE_HOST_DISPLAY=1
    -e HOST_DISPLAY="${HOST_DISPLAY_ENV}"
    -e HOST_XAUTHORITY="${HOST_XAUTHORITY_ENV}"
    -v /tmp/.X11-unix:/tmp/.X11-unix:ro
    -v "${HOST_XAUTHORITY_ENV}:${HOST_XAUTHORITY_ENV}:ro"
  )
else
  docker_args+=(-e GUI_SMOKE_USE_HOST_DISPLAY=0)
fi

"${CONTAINER_ENGINE}" "${docker_args[@]}" \
  "${IMAGE_TAG}" \
  /workspace/scripts/container_gui_smoke_inner.sh || run_status=$?

if [[ -f "${RUN_DIR}/summary.txt" ]]; then
  total_scales="$(grep -c '^scale=' "${RUN_DIR}/summary.txt" || true)"
  blank_failures="$(grep -c 'status=FAIL reason=blank-window' "${RUN_DIR}/summary.txt" || true)"
  if [[ "${total_scales}" != "0" && "${total_scales}" == "${blank_failures}" ]]; then
    echo "Container smoke reproduced a Linux headless WebKit blank-window on every scale." >&2
    echo "Use this environment as an isolated reproducer only, not as a release-grade GUI acceptance environment." >&2
    echo "For real acceptance on a Linux desktop, use scripts/local_gui_vultr_smoke.sh instead." >&2
  fi
fi

exit "${run_status}"
