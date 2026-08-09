#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="${ROOT_DIR}/scripts/install-local-linux.sh"
TMP_DIR="$(mktemp -d /tmp/privatedeploy-local-installer-test.XXXXXX)"
FAKE_PID=""
cleanup() {
  if [[ "${FAKE_PID}" =~ ^[0-9]+$ ]]; then
    kill -TERM "${FAKE_PID}" 2>/dev/null || true
  fi
  rm -rf -- "${TMP_DIR}"
}
trap cleanup EXIT

TEST_HOME="${TMP_DIR}/home"
SOURCE_DIR="${TMP_DIR}/source"
mkdir -p "${TEST_HOME}" "${SOURCE_DIR}"

fail() {
  printf 'install-local-linux test failed: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

# The installer is sourceable so its safety-critical process and ready-state
# matchers can be tested without scanning or signaling real /proc entries.
source "${INSTALLER}"
TARGET_LAUNCHER="${TMP_DIR}/target/PrivateDeploy"
TARGET_RAW_BIN="${TMP_DIR}/target/PrivateDeploy.bin"
TARGET_APPIMAGE="${TMP_DIR}/target/PrivateDeploy.AppImage"
TARGET_TRAY="${TMP_DIR}/target/privatedeploy-tray"
TARGET_CORE="${TMP_DIR}/target/data/sing-box/sing-box"
TARGET_CANONICAL_CORE="${TMP_DIR}/canonical/data/sing-box/sing-box"
SYSTEM_RAW_BIN="${TMP_DIR}/system/privatedeploy.bin"
SYSTEM_TRAY="${TMP_DIR}/system/privatedeploy-tray"

process_matches_install_target "${TARGET_RAW_BIN}" "" "" || fail "exact payload path was not matched"
process_matches_install_target "${TARGET_CORE}" "" "" || fail "exact installed core path was not matched"
process_matches_install_target "${TARGET_CANONICAL_CORE}" "" "" || fail "canonical selected core path was not matched"
process_matches_install_target "${SYSTEM_RAW_BIN}" "" "" || fail "previous package payload was not matched"
if process_matches_install_target "/opt/unrelated/data/sing-box/sing-box" "" ""; then
  fail "unrelated sing-box core was matched"
fi
if process_matches_install_target "/opt/unrelated/PrivateDeploy" "PrivateDeploy" ""; then
  fail "same-name executable outside the install target was matched"
fi
process_matches_install_target "/tmp/.mount_pd/AppRun.wrapped" "" "${TARGET_APPIMAGE}" || \
  fail "AppImage mount with exact APPIMAGE origin was not matched"
if process_matches_install_target "/tmp/.mount_pd/AppRun.wrapped" "PrivateDeploy" "/opt/other.AppImage"; then
  fail "unrelated AppImage mount was matched by display name"
fi
process_matches_install_target "/tmp/.mount_pd/AppRun.wrapped" "${TARGET_APPIMAGE}" "" || \
  fail "AppImage mount with exact argv path was not matched"
if process_matches_install_target "/tmp/.mount_pd/AppRun.wrapped" "${TARGET_APPIMAGE}.old" ""; then
  fail "AppImage argv prefix was treated as an exact target"
fi

missing_proc_output="$(read_proc_nul_file "${TMP_DIR}/missing-proc-file" 2>&1)"
[[ -z "${missing_proc_output}" ]] || fail "unreadable proc files leak permission diagnostics"

matcher_state="${TMP_DIR}/matcher-ready.state"
matcher_nonce="0123456789abcdef0123456789abcdef"
printf 'format=1\npid=4242\nnonce=%s\n' "${matcher_nonce}" >"${matcher_state}"
chmod 0600 "${matcher_state}"
frontend_ready_state_matches "${matcher_state}" 4242 "${matcher_nonce}" || fail "valid ready state was rejected"
if frontend_ready_state_matches "${matcher_state}" 4243 "${matcher_nonce}"; then
  fail "ready state with wrong PID was accepted"
fi
if frontend_ready_state_matches "${matcher_state}" 4242 "wrong-nonce-0000"; then
  fail "ready state with wrong nonce was accepted"
fi

write_payload() {
  local version="$1"
  cat >"${SOURCE_DIR}/PrivateDeploy" <<EOF
#!/usr/bin/env bash
{
  printf 'payload=%s\n' '${version}'
  printf 'base=%s\n' "\${PRIVATEDEPLOY_BASE_PATH:-}"
  printf 'app=%s\n' "\${PRIVATEDEPLOY_APP_NAME:-}"
  printf 'signal=%s\n' "\${JSC_SIGNAL_FOR_GC:-}"
  printf 'jit=%s\n' "\${JSC_useJIT:-}"
  printf 'args=%s\n' "\$*"
} >"\${PD_TEST_OUTPUT:?PD_TEST_OUTPUT is required}"
EOF
  chmod 0755 "${SOURCE_DIR}/PrivateDeploy"
}

write_failing_payload() {
  cat >"${SOURCE_DIR}/PrivateDeploy" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
  chmod 0755 "${SOURCE_DIR}/PrivateDeploy"
}

write_silent_payload() {
  cat >"${SOURCE_DIR}/PrivateDeploy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--privatedeploy-installer-quit" ]] && exit 0
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
EOF
  chmod 0755 "${SOURCE_DIR}/PrivateDeploy"
}

write_ready_payload() {
  cat >"${SOURCE_DIR}/PrivateDeploy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

pid_file="${PD_FAKE_PID_FILE:?PD_FAKE_PID_FILE is required}"
if [[ "${1:-}" == "--privatedeploy-installer-quit" ]]; then
  if [[ -s "${pid_file}" ]]; then
    target_pid="$(cat "${pid_file}")"
    [[ "${target_pid}" =~ ^[0-9]+$ ]] && kill -TERM "${target_pid}" 2>/dev/null || true
  fi
  exit 0
fi

printf '%s\n' "$$" >"${pid_file}"
ready_file="${PRIVATEDEPLOY_FRONTEND_READY_FILE:?ready file is required}"
ready_nonce="${PRIVATEDEPLOY_FRONTEND_READY_NONCE:?ready nonce is required}"
ready_tmp="${ready_file}.tmp.$$"
printf 'format=1\npid=%s\nnonce=%s\n' "$$" "${ready_nonce}" >"${ready_tmp}"
chmod 0600 "${ready_tmp}"
mv -f -- "${ready_tmp}" "${ready_file}"

trap 'exit 0' TERM INT
while :; do
  sleep 1
done
EOF
  chmod 0755 "${SOURCE_DIR}/PrivateDeploy"
}

cat >"${SOURCE_DIR}/sing-box" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${SOURCE_DIR}/privatedeploy-tray" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${SOURCE_DIR}/sing-box" "${SOURCE_DIR}/privatedeploy-tray"

run_installer() {
  local version="$1" commit="$2" no_start="$3"
  HOME="${TEST_HOME}" \
  PRIVATEDEPLOY_SOURCE_BIN="${SOURCE_DIR}/PrivateDeploy" \
  PRIVATEDEPLOY_SOURCE_CORE="${SOURCE_DIR}/sing-box" \
  PRIVATEDEPLOY_SOURCE_TRAY="${SOURCE_DIR}/privatedeploy-tray" \
  PRIVATEDEPLOY_INSTALL_HOME="${TEST_HOME}" \
  PRIVATEDEPLOY_INSTALL_SKIP_STOP=1 \
  PRIVATEDEPLOY_INSTALL_SKIP_BINARY_VALIDATION=1 \
  PRIVATEDEPLOY_INSTALL_NO_START="${no_start}" \
  PRIVATEDEPLOY_INSTALL_HEALTH_TIMEOUT=2 \
  PRIVATEDEPLOY_VERSION="${version}" \
  PRIVATEDEPLOY_COMMIT="${commit}" \
    bash "${INSTALLER}"
}

BIN_DIR="${TEST_HOME}/.local/bin"
DATA_DIR="${BIN_DIR}/data/sing-box"
CANONICAL_DATA_ROOT="${TEST_HOME}/.local/share/PrivateDeploy"
DESKTOP_FILE="${TEST_HOME}/.local/share/applications/privatedeploy.desktop"
ICON_FILE="${TEST_HOME}/.local/share/icons/hicolor/256x256/apps/privatedeploy.png"
INFO_FILE="${BIN_DIR}/PrivateDeploy.install-info"
BACKUP_ROOT="${TEST_HOME}/.local/share/PrivateDeploy/install-backups"

write_payload v1
run_installer 9.9.1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 >"${TMP_DIR}/install-v1.log" 2>&1

for installed in \
  "${BIN_DIR}/PrivateDeploy" \
  "${BIN_DIR}/PrivateDeploy.bin" \
  "${DATA_DIR}/sing-box" \
  "${BIN_DIR}/privatedeploy-tray" \
  "${DESKTOP_FILE}" \
  "${ICON_FILE}" \
  "${INFO_FILE}"; do
  assert_file "${installed}"
done

[[ -x "${BIN_DIR}/PrivateDeploy" ]] || fail "launcher is not executable"
[[ -x "${BIN_DIR}/PrivateDeploy.bin" ]] || fail "payload is not executable"
[[ "$(stat -c '%a' "${INFO_FILE}")" == "600" ]] || fail "install-info permissions are not 0600"
grep -q '^version=9.9.1$' "${INFO_FILE}" || fail "version metadata missing"
grep -q '^commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$' "${INFO_FILE}" || fail "commit metadata missing"
grep -q '^artifact_version_source=explicit$' "${INFO_FILE}" || fail "explicit version source not recorded"
grep -q '^artifact_commit_source=explicit$' "${INFO_FILE}" || fail "explicit commit source not recorded"
grep -q 'JSC_SIGNAL_FOR_GC' "${BIN_DIR}/PrivateDeploy" || fail "JSC signal compatibility is missing"
grep -q 'JSC_useJIT' "${BIN_DIR}/PrivateDeploy" || fail "JSC JIT compatibility is missing"

PD_TEST_OUTPUT="${TMP_DIR}/launcher-v1.out" HOME="${TEST_HOME}" \
  "${BIN_DIR}/PrivateDeploy" first "two words"
grep -q '^payload=v1$' "${TMP_DIR}/launcher-v1.out" || fail "launcher did not execute v1 payload"
grep -q "^base=${CANONICAL_DATA_ROOT}$" "${TMP_DIR}/launcher-v1.out" || \
  fail "runtime-only legacy install was treated as durable user data"
grep -q '^app=PrivateDeploy$' "${TMP_DIR}/launcher-v1.out" || fail "launcher did not preserve app name"
grep -q '^signal=48$' "${TMP_DIR}/launcher-v1.out" || fail "launcher did not set JSC GC signal"
grep -q '^jit=0$' "${TMP_DIR}/launcher-v1.out" || fail "launcher did not disable JSC JIT"
grep -q '^args=first two words$' "${TMP_DIR}/launcher-v1.out" || fail "launcher did not forward arguments"

# With no marker, an existing canonical package data root must win before the
# portable launcher exports an override. Otherwise the backend never gets a
# chance to discover the saved API key and nodes.
mkdir -p "${TEST_HOME}/.config/PrivateDeploy" "${CANONICAL_DATA_ROOT}"
mkdir -p "${CANONICAL_DATA_ROOT}/data/cloud"
printf 'canonical-node-data\n' >"${CANONICAL_DATA_ROOT}/data/cloud/vultr-nodes.json"
# Deliberately older than the core installed above: package/runtime mtimes must
# not hide real user state.
touch -d '@1600000000' "${CANONICAL_DATA_ROOT}/data/cloud/vultr-nodes.json"
rm -f -- "${TEST_HOME}/.config/PrivateDeploy/data-root"
PD_TEST_OUTPUT="${TMP_DIR}/launcher-canonical-root.out" HOME="${TEST_HOME}" \
  "${BIN_DIR}/PrivateDeploy"
grep -q "^base=${CANONICAL_DATA_ROOT}$" "${TMP_DIR}/launcher-canonical-root.out" || \
  fail "launcher ignored canonical data when the data-root marker was absent"
grep -q "^${CANONICAL_DATA_ROOT}$" "${TEST_HOME}/.config/PrivateDeploy/data-root" || \
  fail "launcher did not persist its canonical data-root selection"
[[ "$(stat -c '%a' "${TEST_HOME}/.config/PrivateDeploy/data-root")" == "600" ]] || \
  fail "launcher data-root choice is not private"

# A saved marker is authoritative: later changes in the other root must not
# silently move credentials/nodes between divergent roots.
mkdir -p "${BIN_DIR}/data/cloud"
printf 'legacy-config\n' >"${BIN_DIR}/data/cloud/vultr-config.json"
printf 'legacy-nodes\n' >"${BIN_DIR}/data/cloud/vultr-nodes.json"
touch -d '@1900000000' \
  "${BIN_DIR}/data/cloud/vultr-config.json" \
  "${BIN_DIR}/data/cloud/vultr-nodes.json"
PD_TEST_OUTPUT="${TMP_DIR}/launcher-sticky-root.out" HOME="${TEST_HOME}" \
  "${BIN_DIR}/PrivateDeploy"
grep -q "^base=${CANONICAL_DATA_ROOT}$" "${TMP_DIR}/launcher-sticky-root.out" || \
  fail "launcher changed an already persisted data-root choice"

# Without a marker, the root containing richer/newer real state wins. The
# still-newer installed core is irrelevant to this decision.
rm -f -- "${TEST_HOME}/.config/PrivateDeploy/data-root"
PD_TEST_OUTPUT="${TMP_DIR}/launcher-richer-root.out" HOME="${TEST_HOME}" \
  "${BIN_DIR}/PrivateDeploy"
grep -q "^base=${BIN_DIR}$" "${TMP_DIR}/launcher-richer-root.out" || \
  fail "launcher did not choose the richer durable legacy root"
grep -q "^${BIN_DIR}$" "${TEST_HOME}/.config/PrivateDeploy/data-root" || \
  fail "launcher did not persist the richer durable root"
printf '%s\n' "${BIN_DIR}" >"${TEST_HOME}/.config/PrivateDeploy/data-root"

v1_payload_hash="$(sha256sum "${BIN_DIR}/PrivateDeploy.bin" | awk '{print $1}')"
write_payload v2
run_installer 9.9.2 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 1 >"${TMP_DIR}/install-v2.log" 2>&1

PD_TEST_OUTPUT="${TMP_DIR}/launcher-v2.out" HOME="${TEST_HOME}" "${BIN_DIR}/PrivateDeploy"
grep -q '^payload=v2$' "${TMP_DIR}/launcher-v2.out" || fail "second install did not replace payload"
grep -q '^commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb$' "${INFO_FILE}" || fail "second install metadata missing"

v2_backup="$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -name '*-bbbbbbbbbbbb.*' -print -quit)"
[[ -n "${v2_backup}" ]] || fail "second install did not create a backup"
assert_file "${v2_backup}/item-1"
[[ "$(sha256sum "${v2_backup}/item-1" | awk '{print $1}')" == "${v1_payload_hash}" ]] || \
  fail "backup does not contain the previous payload"

snapshot_before="$(sha256sum \
  "${BIN_DIR}/PrivateDeploy" \
  "${BIN_DIR}/PrivateDeploy.bin" \
  "${DATA_DIR}/sing-box" \
  "${BIN_DIR}/privatedeploy-tray" \
  "${DESKTOP_FILE}" \
  "${ICON_FILE}" \
  "${INFO_FILE}")"

write_failing_payload
if DISPLAY=:99999 run_installer 9.9.3 cccccccccccccccccccccccccccccccccccccccc 0 \
  >"${TMP_DIR}/install-v3-failure.log" 2>&1; then
  fail "installer accepted a payload that exited during startup health check"
fi

grep -q '正在自动回滚' "${TMP_DIR}/install-v3-failure.log" || fail "failed install did not report rollback"
snapshot_after="$(sha256sum \
  "${BIN_DIR}/PrivateDeploy" \
  "${BIN_DIR}/PrivateDeploy.bin" \
  "${DATA_DIR}/sing-box" \
  "${BIN_DIR}/privatedeploy-tray" \
  "${DESKTOP_FILE}" \
  "${ICON_FILE}" \
  "${INFO_FILE}")"
[[ "${snapshot_after}" == "${snapshot_before}" ]] || fail "rollback did not restore the complete v2 install"

PD_TEST_OUTPUT="${TMP_DIR}/launcher-after-rollback.out" HOME="${TEST_HOME}" "${BIN_DIR}/PrivateDeploy"
grep -q '^payload=v2$' "${TMP_DIR}/launcher-after-rollback.out" || fail "rolled-back launcher is not usable"

# A stable process that never mounts Vue must not pass merely because WebKit's
# document callback or the process itself remains alive.
write_silent_payload
if DISPLAY= WAYLAND_DISPLAY=wayland-test \
  run_installer 9.9.31 ccccccccccccccccccccccccccccccccccccccc1 0 \
  >"${TMP_DIR}/install-v31-empty-frontend.log" 2>&1; then
  fail "installer accepted a stable process without a Vue ready signal"
fi
grep -q 'Vue 未确认 #app 成功挂载' "${TMP_DIR}/install-v31-empty-frontend.log" || \
  fail "missing Vue mount timeout diagnostic"
snapshot_after_empty="$(sha256sum \
  "${BIN_DIR}/PrivateDeploy" \
  "${BIN_DIR}/PrivateDeploy.bin" \
  "${DATA_DIR}/sing-box" \
  "${BIN_DIR}/privatedeploy-tray" \
  "${DESKTOP_FILE}" \
  "${ICON_FILE}" \
  "${INFO_FILE}")"
[[ "${snapshot_after_empty}" == "${snapshot_before}" ]] || fail "empty-frontend rollback did not restore v2"

# A Wayland-only session has no DISPLAY and therefore cannot use xdotool or
# wmctrl. The PID+nonce state handshake must still validate both health and the
# final normal launch.
write_ready_payload
if ! DISPLAY= WAYLAND_DISPLAY=wayland-test PD_FAKE_PID_FILE="${TMP_DIR}/fake-app.pid" \
  run_installer 9.9.4 dddddddddddddddddddddddddddddddddddddddd 0 \
  >"${TMP_DIR}/install-v4-wayland.log" 2>&1; then
  cat "${TMP_DIR}/install-v4-wayland.log" >&2
  fail "Wayland frontend-ready install failed"
fi
grep -q 'Vue 前端挂载完成' "${TMP_DIR}/install-v4-wayland.log" || fail "Wayland install did not verify Vue mount"
FAKE_PID="$(cat "${TMP_DIR}/fake-app.pid")"
[[ "${FAKE_PID}" =~ ^[0-9]+$ ]] || fail "Wayland install did not leave a valid app PID"
kill -TERM "${FAKE_PID}" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  kill -0 "${FAKE_PID}" 2>/dev/null || break
  sleep 1
done
kill -KILL "${FAKE_PID}" 2>/dev/null || true
FAKE_PID=""

# AppImages are selected only through an explicit environment value. No mtime
# discovery is allowed, and the selected artifact mode is recorded.
write_payload appimage-v5
cp -- "${SOURCE_DIR}/PrivateDeploy" "${SOURCE_DIR}/explicit.AppImage"
chmod 0755 "${SOURCE_DIR}/explicit.AppImage"
PRIVATEDEPLOY_SOURCE_APPIMAGE="${SOURCE_DIR}/explicit.AppImage" \
  run_installer 9.9.5 eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 1 \
  >"${TMP_DIR}/install-v5-appimage.log" 2>&1
assert_file "${BIN_DIR}/PrivateDeploy.AppImage"
grep -q '^artifact_mode=appimage$' "${INFO_FILE}" || fail "explicit AppImage mode was not recorded"
grep -q '显式指定的兼容包' "${TMP_DIR}/install-v5-appimage.log" || fail "explicit AppImage selection was not reported"
PD_TEST_OUTPUT="${TMP_DIR}/launcher-appimage.out" HOME="${TEST_HOME}" "${BIN_DIR}/PrivateDeploy"
grep -q '^payload=appimage-v5$' "${TMP_DIR}/launcher-appimage.out" || fail "launcher did not execute explicit AppImage"
grep -q '^signal=48$' "${TMP_DIR}/launcher-appimage.out" || fail "AppImage launcher did not set JSC GC signal"
grep -q '^jit=0$' "${TMP_DIR}/launcher-appimage.out" || fail "AppImage launcher did not disable JSC JIT"

# An arbitrary payload without caller-supplied identity must never inherit the
# checkout's current Git HEAD in install metadata.
UNVERIFIED_HOME="${TMP_DIR}/unverified-home"
env -u PRIVATEDEPLOY_VERSION -u PRIVATEDEPLOY_COMMIT \
  HOME="${UNVERIFIED_HOME}" \
  PRIVATEDEPLOY_SOURCE_BIN="${SOURCE_DIR}/PrivateDeploy" \
  PRIVATEDEPLOY_SOURCE_CORE="${SOURCE_DIR}/sing-box" \
  PRIVATEDEPLOY_SOURCE_TRAY="${SOURCE_DIR}/privatedeploy-tray" \
  PRIVATEDEPLOY_INSTALL_HOME="${UNVERIFIED_HOME}" \
  PRIVATEDEPLOY_INSTALL_SKIP_STOP=1 \
  PRIVATEDEPLOY_INSTALL_SKIP_BINARY_VALIDATION=1 \
  PRIVATEDEPLOY_INSTALL_NO_START=1 \
    bash "${INSTALLER}" >"${TMP_DIR}/install-unverified.log" 2>&1
grep -q '^commit=unknown$' "${UNVERIFIED_HOME}/.local/bin/PrivateDeploy.install-info" || \
  fail "unverified payload was labeled with a repository commit"
grep -q '^artifact_commit_source=unknown$' "${UNVERIFIED_HOME}/.local/bin/PrivateDeploy.install-info" || \
  fail "unverified artifact identity was not marked"

# Broken symlinks are legitimate pre-existing filesystem state. A failed
# replacement must restore them exactly instead of treating their backup as
# absent because `test -e` follows the missing target.
BROKEN_HOME="${TMP_DIR}/broken-link-home"
mkdir -p "${BROKEN_HOME}/.local/bin"
ln -s 'missing-old-payload' "${BROKEN_HOME}/.local/bin/PrivateDeploy"
write_silent_payload
if DISPLAY= WAYLAND_DISPLAY=wayland-test \
  HOME="${BROKEN_HOME}" \
  PRIVATEDEPLOY_SOURCE_BIN="${SOURCE_DIR}/PrivateDeploy" \
  PRIVATEDEPLOY_SOURCE_CORE="${SOURCE_DIR}/sing-box" \
  PRIVATEDEPLOY_SOURCE_TRAY="${SOURCE_DIR}/privatedeploy-tray" \
  PRIVATEDEPLOY_INSTALL_HOME="${BROKEN_HOME}" \
  PRIVATEDEPLOY_INSTALL_SKIP_STOP=1 \
  PRIVATEDEPLOY_INSTALL_SKIP_BINARY_VALIDATION=1 \
  PRIVATEDEPLOY_INSTALL_HEALTH_TIMEOUT=2 \
  PRIVATEDEPLOY_VERSION=9.9.6 \
  PRIVATEDEPLOY_COMMIT=ffffffffffffffffffffffffffffffffffffffff \
    bash "${INSTALLER}" >"${TMP_DIR}/install-broken-link.log" 2>&1; then
  fail "broken-link rollback fixture unexpectedly succeeded"
fi
[[ -L "${BROKEN_HOME}/.local/bin/PrivateDeploy" ]] || fail "rollback lost the original broken symlink"
[[ "$(readlink "${BROKEN_HOME}/.local/bin/PrivateDeploy")" == 'missing-old-payload' ]] || \
  fail "rollback changed the original broken symlink target"

printf 'install-local-linux transaction tests OK\n'
