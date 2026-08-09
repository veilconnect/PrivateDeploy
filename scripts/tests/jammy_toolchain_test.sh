#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${ROOT_DIR}/scripts/jammy-build/Dockerfile"

go_mod_version="$(awk '/^go[[:space:]]+/ { print $2; exit }' "${ROOT_DIR}/go.mod")"
docker_go_version="$(awk -F= '/^ARG GO_VERSION=/ { print $2; exit }' "${DOCKERFILE}")"
[[ -n "${go_mod_version}" ]] || { echo 'go.mod has no Go version' >&2; exit 1; }
[[ "${docker_go_version}" == "${go_mod_version}" ]] || {
  printf 'Jammy Docker Go version %s differs from go.mod %s\n' "${docker_go_version}" "${go_mod_version}" >&2
  exit 1
}

frontend_pnpm_version="$(awk -F'pnpm@' '/"packageManager"[[:space:]]*:/ { split($2, parts, "+"); print parts[1]; exit }' "${ROOT_DIR}/frontend/package.json")"
docker_pnpm_version="$(sed -n 's/.*npm install -g pnpm@\([^[:space:]\\]*\).*/\1/p' "${DOCKERFILE}" | head -1)"
[[ -n "${frontend_pnpm_version}" && "${docker_pnpm_version}" == "${frontend_pnpm_version}" ]] || {
  printf 'Jammy Docker pnpm version %s differs from frontend packageManager %s\n' "${docker_pnpm_version:-missing}" "${frontend_pnpm_version:-missing}" >&2
  exit 1
}

grep -q '^export CI=true$' "${ROOT_DIR}/scripts/jammy-build/in-container-build.sh" || {
  echo 'Jammy container frontend build does not force non-interactive CI mode' >&2
  exit 1
}

shell_scripts=(
  "${ROOT_DIR}/scripts/install-local-linux.sh"
  "${ROOT_DIR}/scripts/build-linux-packages.sh"
  "${ROOT_DIR}/scripts/jammy-build/build-appimage-jammy.sh"
  "${ROOT_DIR}/scripts/jammy-build/build-linux-packages-jammy.sh"
  "${ROOT_DIR}/scripts/jammy-build/in-container-appimage.sh"
  "${ROOT_DIR}/scripts/jammy-build/in-container-build.sh"
  "${ROOT_DIR}/scripts/with-patched-wails-linux.sh"
)
for script in "${shell_scripts[@]}"; do
  bash -n "${script}"
done

grep -q 'with-patched-wails-linux.sh' "${ROOT_DIR}/scripts/jammy-build/in-container-build.sh" || {
  echo 'Jammy build bypasses the construct-time WebKit GPU policy patch' >&2
  exit 1
}
grep -q 'webkit_settings_new' "${ROOT_DIR}/patches/wails-v2.12.0-webkit-construct-policy.patch" || {
  echo 'Wails patch does not create settings before the WebView' >&2
  exit 1
}
grep -q 'openBrowserWithCleanEnvironment' "${ROOT_DIR}/patches/wails-v2.12.0-webkit-construct-policy.patch" || {
  echo 'Wails patch leaks AppImage/WebKit renderer variables to external browsers' >&2
  exit 1
}
for blocked_external_environment in \
  GTK_DATA_PREFIX \
  GSETTINGS_SCHEMA_DIR \
  GI_TYPELIB_PATH \
  GTK_IM_MODULE_FILE \
  WEBKIT_EXEC_PATH \
  WEBKIT_INJECTED_BUNDLE_PATH; do
  grep -q "\"${blocked_external_environment}\"" \
    "${ROOT_DIR}/patches/wails-v2.12.0-webkit-construct-policy.patch" || {
    echo "Wails patch leaks ${blocked_external_environment} to external browsers" >&2
    exit 1
  }
done
grep -Fq "patchelf --set-rpath '\$ORIGIN/../../..'" "${ROOT_DIR}/scripts/jammy-build/in-container-appimage.sh" || {
  echo 'injected bundle RUNPATH does not resolve to AppDir/usr/lib' >&2
  exit 1
}
if grep -A1 -F "patchelf --set-rpath '\$ORIGIN/../../..'" \
  "${ROOT_DIR}/scripts/jammy-build/in-container-appimage.sh" | grep -Eq '\|\| true|2>/dev/null'; then
  echo 'injected bundle RUNPATH patch is allowed to fail silently' >&2
  exit 1
fi
grep -Eq 'with_clean_runtime_data\.sh bash scripts/with-patched-wails-linux\.sh .*wails build' \
  "${ROOT_DIR}/.github/workflows/release.yml" || {
  echo 'stable Linux release bypasses the patched Wails build' >&2
  exit 1
}
grep -Eq 'xvfb-run -a bash scripts/with-patched-wails-linux\.sh wails build' \
  "${ROOT_DIR}/.github/workflows/build.yml" || {
  echo 'Linux CI build bypasses the patched Wails build' >&2
  exit 1
}

for host_wrapper in \
  "${ROOT_DIR}/scripts/jammy-build/build-appimage-jammy.sh" \
  "${ROOT_DIR}/scripts/jammy-build/build-linux-packages-jammy.sh"; do
  grep -q -- '--build-arg "GO_VERSION=${GO_VERSION}"' "${host_wrapper}" || {
    echo "Jammy host wrapper does not pass go.mod Go version: ${host_wrapper}" >&2
    exit 1
  }
done

for compatibility_surface in \
  "${ROOT_DIR}/scripts/install-local-linux.sh" \
  "${ROOT_DIR}/scripts/build-linux-packages.sh" \
  "${ROOT_DIR}/scripts/jammy-build/in-container-appimage.sh" \
  "${ROOT_DIR}/scripts/jammy-build/in-container-build.sh"; do
  grep -q 'JSC_SIGNAL_FOR_GC' "${compatibility_surface}" || {
    echo "missing JSC GC signal compatibility: ${compatibility_surface}" >&2
    exit 1
  }
  grep -q 'JSC_useJIT' "${compatibility_surface}" || {
    echo "missing JSC JIT compatibility: ${compatibility_surface}" >&2
    exit 1
  }
  grep -q 'LIBGL_ALWAYS_SOFTWARE' "${compatibility_surface}" || {
    echo "missing software GL compatibility: ${compatibility_surface}" >&2
    exit 1
  }
  grep -q 'WEBKIT_DISABLE_DMABUF_RENDERER' "${compatibility_surface}" || {
    echo "missing DMA-BUF renderer compatibility: ${compatibility_surface}" >&2
    exit 1
  }
  grep -q 'WEBKIT_DISABLE_COMPOSITING_MODE' "${compatibility_surface}" || {
    echo "missing WebKit compositing compatibility: ${compatibility_surface}" >&2
    exit 1
  }
  grep -q 'WEBKIT_SKIA_ENABLE_CPU_RENDERING' "${compatibility_surface}" || {
    echo "missing WebKit Skia CPU rendering compatibility: ${compatibility_surface}" >&2
    exit 1
  }
  grep -q '__EGL_VENDOR_LIBRARY_FILENAMES' "${compatibility_surface}" || {
    echo "missing NVIDIA GLVND isolation: ${compatibility_surface}" >&2
    exit 1
  }
done

grep -q 'PRIVATEDEPLOY_BASE_PATH' "${ROOT_DIR}/scripts/install-local-linux.sh"
grep -q 'PRIVATEDEPLOY_FRONTEND_READY_FILE' "${ROOT_DIR}/scripts/install-local-linux.sh"
grep -q 'PRIVATEDEPLOY_FRONTEND_READY_NONCE' "${ROOT_DIR}/scripts/install-local-linux.sh"
if grep -Eq 'discover_appimage|PRIVATEDEPLOY_INSTALL_PREFER_APPIMAGE|build/bin/jammy/.+AppImage|xdotool|wmctrl|PRIVATEDEPLOY_DEBUG_SIGNAL_TITLE|ALLOW_PROCESS_ONLY_HEALTH' \
  "${ROOT_DIR}/scripts/install-local-linux.sh"; then
  echo 'local installer contains unsafe AppImage discovery or display-server-dependent health logic' >&2
  exit 1
fi
if grep -q 'rev-parse HEAD' "${ROOT_DIR}/scripts/install-local-linux.sh"; then
  echo 'local installer labels arbitrary payloads with checkout HEAD' >&2
  exit 1
fi
if grep -q '/comm' "${ROOT_DIR}/scripts/install-local-linux.sh"; then
  echo 'local installer still matches processes by comm name' >&2
  exit 1
fi
if grep -q 'PRIVATEDEPLOY_DEBUG_SIGNAL_TITLE' "${ROOT_DIR}/main.go"; then
  echo 'Wails OnDomReady still exposes an unconditional frontend-ready title' >&2
  exit 1
fi
grep -q 'SignalFrontendReady' "${ROOT_DIR}/frontend/src/main.ts"
grep -q 'router.isReady' "${ROOT_DIR}/frontend/src/main.ts"
grep -q 'data-application-shell="true"' "${ROOT_DIR}/frontend/src/App.vue"
grep -q 'data-route-view-ready="true"' "${ROOT_DIR}/frontend/src/App.vue"
grep -q 'data-application-shell' "${ROOT_DIR}/frontend/src/utils/frontendReady.ts"
grep -q 'data-route-view-ready' "${ROOT_DIR}/frontend/src/utils/frontendReady.ts"
grep -q 'await waitForFrame()' "${ROOT_DIR}/frontend/src/utils/frontendReady.ts"
grep -q 'applicationReady' "${ROOT_DIR}/frontend/src/utils/frontendReady.ts"
if grep -q 'refreshInstances' "${ROOT_DIR}/frontend/src/router/index.ts"; then
  echo 'initial router guard still blocks navigation on remote instance refresh' >&2
  exit 1
fi
if grep -Eq 'await[[:space:]]+Promise\.allSettled\(\[cloudStore\.fetchRegions' "${ROOT_DIR}/frontend/src/App.vue"; then
  echo 'application readiness still blocks on remote cloud metadata' >&2
  exit 1
fi
for compatibility_surface in \
  "${ROOT_DIR}/scripts/install-local-linux.sh" \
  "${ROOT_DIR}/scripts/build-linux-packages.sh" \
  "${ROOT_DIR}/scripts/jammy-build/in-container-appimage.sh" \
  "${ROOT_DIR}/scripts/jammy-build/in-container-build.sh"; do
  grep -q 'PRIVATEDEPLOY_APP_NAME' "${compatibility_surface}" || {
    echo "missing stable launcher app identity: ${compatibility_surface}" >&2
    exit 1
  }
done

printf 'Jammy/local Linux static checks OK\n'
