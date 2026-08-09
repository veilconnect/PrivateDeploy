#!/usr/bin/env bash
# Transactional per-user Linux installer for PrivateDeploy.
#
# The installed `PrivateDeploy` is deliberately a launcher, not the Wails ELF.
# Ubuntu 24.04's JavaScriptCore otherwise installs its GC handler on SIGUSR1,
# which conflicts with the Go runtime and can terminate the process before the
# WebView paints.  The launcher applies the same JSC compatibility policy as
# the Jammy AppImage and keeps the real binary beside it as PrivateDeploy.bin.

set -Eeuo pipefail

APP_NAME="PrivateDeploy"
INSTALLER_QUIT_ARG="--privatedeploy-installer-quit"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PD_USER_HOME="${PRIVATEDEPLOY_INSTALL_HOME:-${HOME:?HOME is required}}"
SOURCE_BIN="${PRIVATEDEPLOY_SOURCE_BIN:-${REPO_ROOT}/build/bin/${APP_NAME}}"
SOURCE_CORE="${PRIVATEDEPLOY_SOURCE_CORE:-${REPO_ROOT}/build/bin/data/sing-box/sing-box}"
SOURCE_TRAY="${PRIVATEDEPLOY_SOURCE_TRAY:-${REPO_ROOT}/build/bin/privatedeploy-tray}"
SOURCE_APPIMAGE="${PRIVATEDEPLOY_SOURCE_APPIMAGE:-}"

TARGET_BIN_DIR="${PRIVATEDEPLOY_INSTALL_BIN_DIR:-${PD_USER_HOME}/.local/bin}"
TARGET_DATA_DIR="${PRIVATEDEPLOY_INSTALL_DATA_DIR:-${TARGET_BIN_DIR}/data/sing-box}"
TARGET_DESKTOP="${PRIVATEDEPLOY_INSTALL_DESKTOP:-${PD_USER_HOME}/.local/share/applications/privatedeploy.desktop}"
TARGET_ICON="${PRIVATEDEPLOY_INSTALL_ICON:-${PD_USER_HOME}/.local/share/icons/hicolor/256x256/apps/privatedeploy.png}"
TARGET_INFO="${PRIVATEDEPLOY_INSTALL_INFO:-${TARGET_BIN_DIR}/PrivateDeploy.install-info}"
BACKUP_ROOT="${PRIVATEDEPLOY_INSTALL_BACKUP_ROOT:-${PD_USER_HOME}/.local/share/PrivateDeploy/install-backups}"
STATE_DIR="${PRIVATEDEPLOY_INSTALL_STATE_DIR:-${PD_USER_HOME}/.local/state/PrivateDeploy}"

TARGET_LAUNCHER="${TARGET_BIN_DIR}/${APP_NAME}"
TARGET_RAW_BIN="${TARGET_BIN_DIR}/${APP_NAME}.bin"
TARGET_APPIMAGE="${TARGET_BIN_DIR}/${APP_NAME}.AppImage"
TARGET_CORE="${TARGET_DATA_DIR}/sing-box"
TARGET_TRAY="${TARGET_BIN_DIR}/privatedeploy-tray"
TARGET_CANONICAL_CORE="${PD_USER_HOME}/.local/share/PrivateDeploy/data/sing-box/sing-box"
SYSTEM_RAW_BIN="/usr/lib/privatedeploy/privatedeploy.bin"
SYSTEM_TRAY="/usr/lib/privatedeploy/privatedeploy-tray"

NO_START="${PRIVATEDEPLOY_INSTALL_NO_START:-0}"
SKIP_STOP="${PRIVATEDEPLOY_INSTALL_SKIP_STOP:-0}"
SKIP_BINARY_VALIDATION="${PRIVATEDEPLOY_INSTALL_SKIP_BINARY_VALIDATION:-0}"
HEALTH_TIMEOUT="${PRIVATEDEPLOY_INSTALL_HEALTH_TIMEOUT:-25}"

STAGE_DIR=""
BACKUP_DIR=""
TRANSACTION_ACTIVE=0
INSTALL_COMMITTED=0
HAD_RUNNING_INSTANCE=0
NEW_PROCESS_PID=""
HEALTH_PROCESS_PID=""
HEALTH_READY_FILE=""
NEW_READY_FILE=""
HEALTH_DATA_DIR=""

declare -a TX_TARGETS=()
declare -a TX_STAGED=()
declare -a TX_MODES=()
declare -a TX_EXISTED=()

log() {
  printf '%s\n' "$*"
}

warn() {
  printf '⚠️  %s\n' "$*" >&2
}

die() {
  printf '❌ %s\n' "$*" >&2
  return 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

paths_refer_to_same_file() {
  local first="$1" second="$2" first_real second_real
  [[ "${first}" == "${second}" ]] && return 0
  [[ -e "${first}" && -e "${second}" ]] || return 1
  first_real="$(readlink -f -- "${first}" 2>/dev/null || true)"
  second_real="$(readlink -f -- "${second}" 2>/dev/null || true)"
  [[ -n "${first_real}" && "${first_real}" == "${second_real}" ]]
}

process_matches_install_target() {
  local exe="$1" cmdline_args="$2" appimage_env="$3" arg

  case "${exe}" in
    "${TARGET_LAUNCHER}"|"${TARGET_RAW_BIN}"|"${TARGET_APPIMAGE}"|"${TARGET_TRAY}"|"${TARGET_CORE}"|\
    "${TARGET_CANONICAL_CORE}"|"${SYSTEM_RAW_BIN}"|"${SYSTEM_TRAY}")
      return 0
      ;;
  esac

  # AppImage replaces its original executable with a binary under a private
  # /tmp/.mount_* tree. Only accept that process when /proc ties it back to the
  # exact AppImage installed by this script; a matching comm/name is unsafe.
  case "${exe}" in
    /tmp/.mount_*/*|/run/user/*/.mount_*/*)
      if [[ -n "${appimage_env}" ]] && paths_refer_to_same_file "${appimage_env}" "${TARGET_APPIMAGE}"; then
        return 0
      fi
      while IFS= read -r arg; do
        if [[ -n "${arg}" ]] && paths_refer_to_same_file "${arg}" "${TARGET_APPIMAGE}"; then
          return 0
        fi
      done <<<"${cmdline_args}"
      ;;
  esac
  return 1
}

current_user_processes() {
  local proc_dir pid proc_uid exe cmdline_args appimage_env entry
  local current_uid
  current_uid="$(id -u)"

  for proc_dir in /proc/[0-9]*; do
    [[ -r "${proc_dir}/status" ]] || continue
    pid="${proc_dir##*/}"
    [[ "${pid}" != "$$" ]] || continue
    proc_uid="$(awk '/^Uid:/ {print $2; exit}' "${proc_dir}/status" 2>/dev/null || true)"
    [[ "${proc_uid}" == "${current_uid}" ]] || continue

    exe="$(readlink "${proc_dir}/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"
    cmdline_args="$(tr '\0' '\n' <"${proc_dir}/cmdline" 2>/dev/null || true)"
    appimage_env=""
    while IFS= read -r entry; do
      case "${entry}" in
        APPIMAGE=*)
          appimage_env="${entry#APPIMAGE=}"
          break
          ;;
      esac
    done < <(tr '\0' '\n' <"${proc_dir}/environ" 2>/dev/null || true)

    if process_matches_install_target "${exe}" "${cmdline_args}" "${appimage_env}"; then
      printf '%s\n' "${pid}"
    fi
  done | sort -n -u
}

wait_for_processes_to_exit() {
  local timeout_sec="$1"
  local deadline=$((SECONDS + timeout_sec))
  local pids
  while (( SECONDS < deadline )); do
    pids="$(current_user_processes)"
    [[ -z "${pids}" ]] && return 0
    sleep 1
  done
  return 1
}

stop_existing_app() {
  [[ "${SKIP_STOP}" == "1" ]] && return 0

  local pids
  pids="$(current_user_processes)"
  [[ -n "${pids}" ]] || return 0
  HAD_RUNNING_INSTANCE=1
  log "==> 正在优雅关闭旧版 PrivateDeploy"

  if [[ -x "${TARGET_LAUNCHER}" ]]; then
    timeout 8s "${TARGET_LAUNCHER}" "${INSTALLER_QUIT_ARG}" >/dev/null 2>&1 || true
  elif [[ -x "${TARGET_RAW_BIN}" ]]; then
    timeout 8s "${TARGET_RAW_BIN}" "${INSTALLER_QUIT_ARG}" >/dev/null 2>&1 || true
  fi

  if wait_for_processes_to_exit 16; then
    return 0
  fi

  pids="$(current_user_processes)"
  if [[ -n "${pids}" ]]; then
    warn "旧进程未响应退出请求，发送 SIGTERM: ${pids//$'\n'/ }"
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
    done <<<"${pids}"
  fi
  if wait_for_processes_to_exit 6; then
    return 0
  fi

  pids="$(current_user_processes)"
  if [[ -n "${pids}" ]]; then
    warn "旧进程仍未退出，发送 SIGKILL: ${pids//$'\n'/ }"
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && kill -KILL "${pid}" 2>/dev/null || true
    done <<<"${pids}"
  fi
  wait_for_processes_to_exit 3 || die "无法停止正在运行的旧版 PrivateDeploy"
}

validate_elf_arch() {
  local path="$1" label="$2"
  [[ -f "${path}" && -x "${path}" ]] || die "${label} 不存在或不可执行: ${path}"
  [[ "${SKIP_BINARY_VALIDATION}" == "1" ]] && return 0

  local description machine
  description="$(file -Lb "${path}")"
  [[ "${description}" == *ELF* ]] || die "${label} 不是 Linux ELF 可执行文件: ${description}"

  machine="$(uname -m)"
  case "${machine}" in
    x86_64)
      [[ "${description}" == *x86-64* || "${description}" == *x86_64* ]] || die "${label} 架构与主机不匹配: ${description}"
      ;;
    aarch64|arm64)
      [[ "${description}" == *ARM\ aarch64* || "${description}" == *ARM64* ]] || die "${label} 架构与主机不匹配: ${description}"
      ;;
  esac
}

validate_payload() {
  local payload="$1" mode="$2"
  validate_elf_arch "${payload}" "PrivateDeploy ${mode} 构建产物"
  if [[ "${SKIP_BINARY_VALIDATION}" != "1" && "${mode}" == "raw" ]]; then
    local ldd_output
    ldd_output="$(ldd "${payload}" 2>&1 || true)"
    if [[ "${ldd_output}" == *"not found"* ]]; then
      printf '%s\n' "${ldd_output}" >&2
      die "PrivateDeploy 缺少运行时共享库"
    fi
  fi
}

derive_version() {
  if [[ -n "${PRIVATEDEPLOY_VERSION:-}" ]]; then
    printf '%s' "${PRIVATEDEPLOY_VERSION}"
    return
  fi
  if [[ -f "${REPO_ROOT}/frontend/package.json" ]]; then
    awk -F'"' '/"version"[[:space:]]*:/ {print $4; exit}' "${REPO_ROOT}/frontend/package.json"
    return
  fi
  printf 'dev'
}

derive_commit() {
  if [[ -n "${PRIVATEDEPLOY_COMMIT:-}" ]]; then
    printf '%s' "${PRIVATEDEPLOY_COMMIT}"
    return
  fi
  # A binary in build/bin may predate the current checkout. Never label an
  # unknown artifact with the repository's current HEAD.
  printf 'unknown'
}

build_tray_if_needed() {
  local destination="$1" version="$2"
  if [[ -f "${SOURCE_TRAY}" && -x "${SOURCE_TRAY}" ]]; then
    cp -- "${SOURCE_TRAY}" "${destination}"
    return 0
  fi

  command_exists go || die "缺少托盘构建产物且系统没有 go: ${SOURCE_TRAY}"
  log "==> 未找到托盘构建产物，正在生成静态托盘 sidecar"
  (
    cd "${REPO_ROOT}"
    CGO_ENABLED=0 GOOS=linux GOARCH="$(go env GOARCH)" go build \
      -trimpath -buildvcs=false \
      -ldflags="-X privatedeploy/bridge.AppVersion=v${version}" \
      -o "${destination}" \
      ./cmd/privatedeploy-tray/
  )
  chmod 0755 "${destination}"
}

write_launcher() {
  local destination="$1" payload_basename="$2"
  cat >"${destination}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

PD_LAUNCH_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PD_REAL_BINARY="\${PD_LAUNCH_DIR}/${payload_basename}"

if [[ ! -x "\${PD_REAL_BINARY}" ]]; then
  printf 'PrivateDeploy payload is missing or not executable: %s\\n' "\${PD_REAL_BINARY}" >&2
  exit 127
fi

# Keep one durable data-root choice across the portable, AppImage and package
# launchers.  Older portable installs stored data beside the binary, while
# packages used ~/.local/share/PrivateDeploy. The launcher records one safe
# selection after inspecting both locations, and every packaging surface then
# follows that same marker.
if [[ -z "\${PRIVATEDEPLOY_BASE_PATH:-}" ]]; then
  PD_CANONICAL_DATA_ROOT="\${HOME}/.local/share/PrivateDeploy"
  PD_LEGACY_DATA_ROOT="\${HOME}/.local/bin"
  PD_DATA_ROOT_CHOICE="\${HOME}/.config/PrivateDeploy/data-root"
  PD_SELECTED_DATA_ROOT=""
  if [[ -f "\${PD_DATA_ROOT_CHOICE}" && ! -L "\${PD_DATA_ROOT_CHOICE}" ]]; then
    IFS= read -r PD_SELECTED_DATA_ROOT <"\${PD_DATA_ROOT_CHOICE}" || true
  fi
  case "\${PD_SELECTED_DATA_ROOT}" in
    "\${PD_CANONICAL_DATA_ROOT}"|"\${PD_LEGACY_DATA_ROOT}") ;;
    *)
      # No marker exists on the first upgraded launch. Inspect both historical
      # roots before setting the override; otherwise forcing ~/.local/bin here
      # prevents the backend from ever seeing package data in ~/.local/share.
      PD_CANONICAL_SCORE=0
      PD_CANONICAL_NEWEST=0
      PD_LEGACY_SCORE=0
      PD_LEGACY_NEWEST=0
      # Only saved user/provider state participates. Installed cores, cache
      # assets, sing-box runtime files, operation locks/journals and other
      # build products must not steal the selection from a real data root.
      pd_durable_state_weight() {
        local PD_RELATIVE_DATA_FILE="\$1"
        case "\${PD_RELATIVE_DATA_FILE}" in
          user.yaml|profiles.yaml|subscribes.yaml|rulesets.yaml|plugins.yaml|scheduledtasks.yaml)
            printf '16'
            ;;
          privatedeploy.db)
            printf '8'
            ;;
          cloud/active-provider)
            printf '32'
            ;;
          cloud/*-nodes.json)
            [[ "\${PD_RELATIVE_DATA_FILE#cloud/}" != */* ]] && printf '64' || printf '0'
            ;;
          cloud/*-config.json)
            [[ "\${PD_RELATIVE_DATA_FILE#cloud/}" != */* ]] && printf '32' || printf '0'
            ;;
          cloud/ssh-known-hosts.json)
            printf '16'
            ;;
          subscribes/*.json|subscribes/*.yaml|subscribes/*.yml)
            [[ "\${PD_RELATIVE_DATA_FILE#subscribes/}" != */* ]] && printf '8' || printf '0'
            ;;
          cdn/config.json|cdn/deployments.json)
            printf '16'
            ;;
          *)
            printf '0'
            ;;
        esac
      }
      while IFS= read -r -d '' PD_DATA_FILE; do
        PD_RELATIVE_DATA_FILE="\${PD_DATA_FILE#\${PD_CANONICAL_DATA_ROOT}/data/}"
        PD_FILE_WEIGHT="\$(pd_durable_state_weight "\${PD_RELATIVE_DATA_FILE}")"
        (( PD_FILE_WEIGHT > 0 )) || continue
        PD_FILE_TIME="\$(stat -c '%Y' "\${PD_DATA_FILE}" 2>/dev/null || printf '0')"
        PD_CANONICAL_SCORE=\$((PD_CANONICAL_SCORE + PD_FILE_WEIGHT))
        (( PD_FILE_TIME > PD_CANONICAL_NEWEST )) && PD_CANONICAL_NEWEST="\${PD_FILE_TIME}"
      done < <(find "\${PD_CANONICAL_DATA_ROOT}/data" -type f -print0 2>/dev/null || true)
      while IFS= read -r -d '' PD_DATA_FILE; do
        PD_RELATIVE_DATA_FILE="\${PD_DATA_FILE#\${PD_LEGACY_DATA_ROOT}/data/}"
        PD_FILE_WEIGHT="\$(pd_durable_state_weight "\${PD_RELATIVE_DATA_FILE}")"
        (( PD_FILE_WEIGHT > 0 )) || continue
        PD_FILE_TIME="\$(stat -c '%Y' "\${PD_DATA_FILE}" 2>/dev/null || printf '0')"
        PD_LEGACY_SCORE=\$((PD_LEGACY_SCORE + PD_FILE_WEIGHT))
        (( PD_FILE_TIME > PD_LEGACY_NEWEST )) && PD_LEGACY_NEWEST="\${PD_FILE_TIME}"
      done < <(find "\${PD_LEGACY_DATA_ROOT}/data" -type f -print0 2>/dev/null || true)

      PD_SELECTED_DATA_ROOT="\${PD_CANONICAL_DATA_ROOT}"
      if (( PD_LEGACY_SCORE > PD_CANONICAL_SCORE )) || \
         (( PD_LEGACY_SCORE > 0 && PD_LEGACY_SCORE == PD_CANONICAL_SCORE && PD_LEGACY_NEWEST > PD_CANONICAL_NEWEST )); then
        PD_SELECTED_DATA_ROOT="\${PD_LEGACY_DATA_ROOT}"
      fi
      mkdir -p "\$(dirname "\${PD_DATA_ROOT_CHOICE}")"
      chmod 0700 "\$(dirname "\${PD_DATA_ROOT_CHOICE}")" 2>/dev/null || true
      PD_CHOICE_TMP="\$(mktemp "\$(dirname "\${PD_DATA_ROOT_CHOICE}")/.data-root.XXXXXX")"
      chmod 0600 "\${PD_CHOICE_TMP}"
      printf '%s\n' "\${PD_SELECTED_DATA_ROOT}" >"\${PD_CHOICE_TMP}"
      mv -f -- "\${PD_CHOICE_TMP}" "\${PD_DATA_ROOT_CHOICE}"
      ;;
  esac
  export PRIVATEDEPLOY_BASE_PATH="\${PD_SELECTED_DATA_ROOT}"
fi
export PRIVATEDEPLOY_APP_NAME="\${PRIVATEDEPLOY_APP_NAME:-PrivateDeploy}"

# JavaScriptCoreGTK on Ubuntu 24.04 otherwise uses SIGUSR1 (signal 10) for GC,
# colliding with Go/Wails during gtk_main and producing a blank or dead window.
# These are the same compatibility settings used by the Jammy AppImage.
export JSC_SIGNAL_FOR_GC="\${JSC_SIGNAL_FOR_GC:-48}"
export JSC_useJIT="\${JSC_useJIT:-0}"

PD_STATE_DIR="\${PRIVATEDEPLOY_STATE_DIR:-\${XDG_STATE_HOME:-\${HOME}/.local/state}/PrivateDeploy}"
mkdir -p "\${PD_STATE_DIR}" 2>/dev/null || true
export PRIVATEDEPLOY_LOG_FILE="\${PRIVATEDEPLOY_LOG_FILE:-\${PD_STATE_DIR}/desktop.log}"

exec -a PrivateDeploy "\${PD_REAL_BINARY}" "\$@"
EOF
  chmod 0755 "${destination}"
  bash -n "${destination}"
}

write_desktop_file() {
  local destination="$1"
  cat >"${destination}" <<EOF
[Desktop Entry]
Type=Application
Name=PrivateDeploy
Comment=PrivateDeploy Desktop
Exec=${TARGET_LAUNCHER}
Icon=privatedeploy
Terminal=false
Categories=Network;Utility;
StartupNotify=true
StartupWMClass=PrivateDeploy
EOF
}

atomic_install() {
  local source="$1" target="$2" mode="$3"
  local target_dir temp_target
  target_dir="$(dirname "${target}")"
  mkdir -p "${target_dir}"
  temp_target="$(mktemp "${target_dir}/.$(basename "${target}").install.XXXXXX")"
  cp -- "${source}" "${temp_target}"
  chmod "${mode}" "${temp_target}"
  [[ "$(sha256_file "${source}")" == "$(sha256_file "${temp_target}")" ]] || {
    rm -f -- "${temp_target}"
    die "复制校验失败: ${target}"
  }
  mv -f -- "${temp_target}" "${target}"
}

prepare_transaction() {
  local timestamp="$1" commit_short="$2"
  local i target

  BACKUP_DIR="$(mktemp -d "${BACKUP_ROOT}/${timestamp}-${commit_short}.XXXXXX")"

  TX_EXISTED=()
  for ((i = 0; i < ${#TX_TARGETS[@]}; i++)); do
    target="${TX_TARGETS[$i]}"
    if [[ -e "${target}" || -L "${target}" ]]; then
      TX_EXISTED+=(1)
      cp -a -- "${target}" "${BACKUP_DIR}/item-${i}"
    else
      TX_EXISTED+=(0)
    fi
  done
  TRANSACTION_ACTIVE=1
}

install_transaction() {
  local i
  for ((i = 0; i < ${#TX_TARGETS[@]}; i++)); do
    atomic_install "${TX_STAGED[$i]}" "${TX_TARGETS[$i]}" "${TX_MODES[$i]}"
  done
}

terminate_pid() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  kill -0 "${pid}" 2>/dev/null || return 0
  kill -TERM "${pid}" 2>/dev/null || true
  local deadline=$((SECONDS + 5))
  while kill -0 "${pid}" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 1
  done
  kill -KILL "${pid}" 2>/dev/null || true
}

rollback_install() {
  [[ "${TRANSACTION_ACTIVE}" == "1" ]] || return 0
  warn "安装或启动验证失败，正在自动回滚"

  terminate_pid "${HEALTH_PROCESS_PID}"
  terminate_pid "${NEW_PROCESS_PID}"

  local i target backup_item restore_tmp
  for ((i = ${#TX_TARGETS[@]} - 1; i >= 0; i--)); do
    target="${TX_TARGETS[$i]}"
    backup_item="${BACKUP_DIR}/item-${i}"
    if [[ "${TX_EXISTED[$i]}" == "1" && ( -e "${backup_item}" || -L "${backup_item}" ) ]]; then
      restore_tmp="$(mktemp "$(dirname "${target}")/.$(basename "${target}").rollback.XXXXXX")"
      rm -f -- "${restore_tmp}"
      cp -a -- "${backup_item}" "${restore_tmp}"
      mv -f -- "${restore_tmp}" "${target}"
    else
      rm -f -- "${target}"
    fi
  done

  TRANSACTION_ACTIVE=0
  if [[ "${HAD_RUNNING_INSTANCE}" == "1" && -x "${TARGET_LAUNCHER}" && "${NO_START}" != "1" ]] && \
    [[ -z "$(current_user_processes)" ]]; then
    warn "正在重新启动已回滚的旧版本"
    nohup "${TARGET_LAUNCHER}" >>"${STATE_DIR}/rollback-start.log" 2>&1 &
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "${status}" -ne 0 && "${INSTALL_COMMITTED}" != "1" ]]; then
    rollback_install || true
  fi
  [[ -z "${STAGE_DIR}" ]] || rm -rf -- "${STAGE_DIR}"
  [[ -z "${HEALTH_READY_FILE}" ]] || rm -f -- "${HEALTH_READY_FILE}"
  [[ -z "${NEW_READY_FILE}" ]] || rm -f -- "${NEW_READY_FILE}"
  [[ -z "${HEALTH_DATA_DIR}" ]] || rm -rf -- "${HEALTH_DATA_DIR}"
  exit "${status}"
}

fatal_startup_log() {
  local log_file="$1"
  [[ -f "${log_file}" ]] || return 1
  grep -Eqi 'Overriding existing handler for signal 10|SIGSEGV|segmentation fault|fatal error:|failed to init GTK|Trace/breakpoint trap|renders blank windows' "${log_file}"
}

generate_ready_nonce() {
  local nonce
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    nonce="$(tr -d -- '-' </proc/sys/kernel/random/uuid)"
  else
    nonce="$(printf '%s' "$$-${RANDOM}-${RANDOM}-$(date +%s%N)" | sha256sum | awk '{print $1}')"
  fi
  [[ "${nonce}" =~ ^[[:alnum:]_.-]{16,128}$ ]] || die "无法生成前端健康检查 nonce"
  printf '%s' "${nonce}"
}

frontend_ready_state_matches() {
  local state_file="$1" expected_pid="$2" expected_nonce="$3"
  local state_pid state_nonce owner mode
  [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1

  owner="$(stat -c '%u' "${state_file}" 2>/dev/null || true)"
  mode="$(stat -c '%a' "${state_file}" 2>/dev/null || true)"
  [[ "${owner}" == "$(id -u)" ]] || return 1
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#${mode} & 0077) == 0 )) || return 1

  state_pid="$(awk -F= '$1 == "pid" {print substr($0, 5); exit}' "${state_file}" 2>/dev/null || true)"
  state_nonce="$(awk -F= '$1 == "nonce" {print substr($0, 7); exit}' "${state_file}" 2>/dev/null || true)"
  [[ "${state_pid}" == "${expected_pid}" && "${state_nonce}" == "${expected_nonce}" ]]
}

run_dom_health_check() {
  local nonce signal_title log_file stdout_file deadline
  nonce="$(generate_ready_nonce)"
  signal_title="PrivateDeploy-install-health-${nonce:0:12}"
  HEALTH_READY_FILE="${STATE_DIR}/frontend-ready-health-${nonce}.state"
  log_file="${STATE_DIR}/install-health.log"
  stdout_file="${STATE_DIR}/install-health.stdout.log"
  rm -f -- "${HEALTH_READY_FILE}"
  : >"${log_file}"
  : >"${stdout_file}"

  # The compatibility smoke must not run migrations, plugins or cloud loading
  # against the user's production data. It exercises the installed payload and
  # complete Vue bootstrap in an isolated disposable profile; the normal app is
  # then started exactly once with the real profile.
  HEALTH_DATA_DIR="$(mktemp -d /tmp/privatedeploy-install-health.XXXXXX)"
  mkdir -p "${HEALTH_DATA_DIR}/base" "${HEALTH_DATA_DIR}/config" \
    "${HEALTH_DATA_DIR}/cache" "${HEALTH_DATA_DIR}/data" "${HEALTH_DATA_DIR}/state" \
    "${HEALTH_DATA_DIR}/secrets"
  chmod 0700 "${HEALTH_DATA_DIR}" "${HEALTH_DATA_DIR}"/*

  log "==> 启动兼容性自检（Vue mount + WebKit，支持 X11/Wayland）"
  PRIVATEDEPLOY_LOG_FILE="${log_file}" \
  PRIVATEDEPLOY_BASE_PATH="${HEALTH_DATA_DIR}/base" \
  PRIVATEDEPLOY_SECRET_STORE_DIR="${HEALTH_DATA_DIR}/secrets" \
  PRIVATEDEPLOY_FRONTEND_READY_FILE="${HEALTH_READY_FILE}" \
  PRIVATEDEPLOY_FRONTEND_READY_NONCE="${nonce}" \
  PRIVATEDEPLOY_FRONTEND_READY_TITLE="${signal_title}" \
  PRIVATEDEPLOY_DISABLE_TRAY=1 \
  PRIVATEDEPLOY_SKIP_ROLLING_RELEASE=1 \
  XDG_CONFIG_HOME="${HEALTH_DATA_DIR}/config" \
  XDG_CACHE_HOME="${HEALTH_DATA_DIR}/cache" \
  XDG_DATA_HOME="${HEALTH_DATA_DIR}/data" \
  XDG_STATE_HOME="${HEALTH_DATA_DIR}/state" \
    "${TARGET_LAUNCHER}" >>"${stdout_file}" 2>&1 &
  HEALTH_PROCESS_PID=$!
  deadline=$((SECONDS + HEALTH_TIMEOUT))

  while (( SECONDS < deadline )); do
    if ! kill -0 "${HEALTH_PROCESS_PID}" 2>/dev/null; then
      fatal_startup_log "${log_file}" && tail -40 "${log_file}" >&2 || true
      tail -40 "${stdout_file}" >&2 || true
      die "PrivateDeploy 在 WebKit 自检期间提前退出"
    fi
    if fatal_startup_log "${log_file}" || fatal_startup_log "${stdout_file}"; then
      tail -40 "${log_file}" >&2 || true
      tail -40 "${stdout_file}" >&2 || true
      die "检测到 WebKit/JSC 启动崩溃"
    fi
    if frontend_ready_state_matches "${HEALTH_READY_FILE}" "${HEALTH_PROCESS_PID}" "${nonce}"; then
      log "✅ Vue 前端挂载与 WebKit 自检通过 (PID ${HEALTH_PROCESS_PID})"
      return 0
    fi
    sleep 1
  done

  die "PrivateDeploy 进程仍在运行，但 Vue 未确认 #app 成功挂载"
}

stop_health_instance() {
  [[ -n "${HEALTH_PROCESS_PID}" ]] || return 0
  if [[ -x "${TARGET_LAUNCHER}" ]]; then
    PRIVATEDEPLOY_BASE_PATH="${HEALTH_DATA_DIR}/base" \
    PRIVATEDEPLOY_SECRET_STORE_DIR="${HEALTH_DATA_DIR}/secrets" \
    PRIVATEDEPLOY_DISABLE_TRAY=1 \
    PRIVATEDEPLOY_SKIP_ROLLING_RELEASE=1 \
    XDG_CONFIG_HOME="${HEALTH_DATA_DIR}/config" \
    XDG_CACHE_HOME="${HEALTH_DATA_DIR}/cache" \
    XDG_DATA_HOME="${HEALTH_DATA_DIR}/data" \
    XDG_STATE_HOME="${HEALTH_DATA_DIR}/state" \
      timeout 8s "${TARGET_LAUNCHER}" "${INSTALLER_QUIT_ARG}" >/dev/null 2>&1 || true
  fi
  local deadline=$((SECONDS + 10))
  while kill -0 "${HEALTH_PROCESS_PID}" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 1
  done
  terminate_pid "${HEALTH_PROCESS_PID}"
  HEALTH_PROCESS_PID=""
  rm -f -- "${HEALTH_READY_FILE}"
  HEALTH_READY_FILE=""
  rm -rf -- "${HEALTH_DATA_DIR}"
  HEALTH_DATA_DIR=""
}

start_normal_instance() {
  local nonce log_file deadline
  nonce="$(generate_ready_nonce)"
  NEW_READY_FILE="${STATE_DIR}/frontend-ready-start-${nonce}.state"
  log_file="${STATE_DIR}/desktop-start.log"
  rm -f -- "${NEW_READY_FILE}"
  : >"${log_file}"
  log "==> 启动 PrivateDeploy"
  PRIVATEDEPLOY_LOG_FILE="${log_file}" \
  PRIVATEDEPLOY_FRONTEND_READY_FILE="${NEW_READY_FILE}" \
  PRIVATEDEPLOY_FRONTEND_READY_NONCE="${nonce}" \
    nohup "${TARGET_LAUNCHER}" >>"${log_file}" 2>&1 &
  NEW_PROCESS_PID=$!
  deadline=$((SECONDS + HEALTH_TIMEOUT))

  while (( SECONDS < deadline )); do
    if ! kill -0 "${NEW_PROCESS_PID}" 2>/dev/null; then
      tail -60 "${log_file}" >&2 || true
      die "新安装的 PrivateDeploy 启动后提前退出"
    fi
    if fatal_startup_log "${log_file}"; then
      tail -60 "${log_file}" >&2 || true
      die "新安装的 PrivateDeploy 出现 WebKit/JSC 崩溃"
    fi
    if frontend_ready_state_matches "${NEW_READY_FILE}" "${NEW_PROCESS_PID}" "${nonce}"; then
      rm -f -- "${NEW_READY_FILE}"
      NEW_READY_FILE=""
      log "✅ PrivateDeploy 已启动，Vue 前端挂载完成 (PID ${NEW_PROCESS_PID})"
      return 0
    fi
    sleep 1
  done

  die "PrivateDeploy 已启动，但 Vue 未确认 #app 成功挂载"
}

main() {
  trap on_exit EXIT
  [[ "$(uname -s)" == "Linux" ]] || die "此安装脚本仅支持 Linux"
  command_exists sha256sum || die "缺少 sha256sum"
  command_exists file || die "缺少 file"
  command_exists timeout || die "缺少 timeout"

  local payload payload_mode payload_basename
  if [[ -n "${SOURCE_APPIMAGE}" ]]; then
    log "==> 使用 PRIVATEDEPLOY_SOURCE_APPIMAGE 显式指定的兼容包"
    payload="${SOURCE_APPIMAGE}"
    payload_mode="appimage"
    payload_basename="$(basename "${TARGET_APPIMAGE}")"
  else
    payload="${SOURCE_BIN}"
    payload_mode="raw"
    payload_basename="$(basename "${TARGET_RAW_BIN}")"
  fi

  validate_payload "${payload}" "${payload_mode}"
  validate_elf_arch "${SOURCE_CORE}" "sing-box core"

  local version commit commit_short timestamp payload_hash core_hash tray_hash
  local version_source="package-metadata-unverified" commit_source="unknown"
  version="$(derive_version)"
  commit="$(derive_commit)"
  [[ -z "${PRIVATEDEPLOY_VERSION:-}" ]] || version_source="explicit"
  [[ -z "${PRIVATEDEPLOY_COMMIT:-}" ]] || commit_source="explicit"
  commit_short="${commit:0:12}"
  [[ -n "${commit_short}" ]] || commit_short="unknown"
  commit_short="${commit_short//[^[:alnum:]._-]/_}"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

  mkdir -p "${TARGET_BIN_DIR}" "${TARGET_DATA_DIR}" "$(dirname "${TARGET_DESKTOP}")" \
    "$(dirname "${TARGET_ICON}")" "$(dirname "${TARGET_INFO}")" "${BACKUP_ROOT}" "${STATE_DIR}"
  chmod 0700 "${STATE_DIR}" 2>/dev/null || true

  STAGE_DIR="$(mktemp -d "${TARGET_BIN_DIR}/.privatedeploy-stage.XXXXXX")"
  cp -- "${payload}" "${STAGE_DIR}/${payload_basename}"
  chmod 0755 "${STAGE_DIR}/${payload_basename}"
  cp -- "${SOURCE_CORE}" "${STAGE_DIR}/sing-box"
  chmod 0755 "${STAGE_DIR}/sing-box"
  build_tray_if_needed "${STAGE_DIR}/privatedeploy-tray" "${version}"
  validate_elf_arch "${STAGE_DIR}/privatedeploy-tray" "privatedeploy-tray"

  write_launcher "${STAGE_DIR}/${APP_NAME}" "${payload_basename}"
  write_desktop_file "${STAGE_DIR}/privatedeploy.desktop"
  if command_exists desktop-file-validate; then
    desktop-file-validate "${STAGE_DIR}/privatedeploy.desktop"
  fi

  local staged_icon="${STAGE_DIR}/privatedeploy.png"
  if [[ -f "${REPO_ROOT}/build/appicon.png" ]]; then
    cp -- "${REPO_ROOT}/build/appicon.png" "${staged_icon}"
  elif [[ -f "${TARGET_ICON}" ]]; then
    cp -- "${TARGET_ICON}" "${staged_icon}"
  else
    die "缺少应用图标: ${REPO_ROOT}/build/appicon.png"
  fi

  payload_hash="$(sha256_file "${STAGE_DIR}/${payload_basename}")"
  core_hash="$(sha256_file "${STAGE_DIR}/sing-box")"
  tray_hash="$(sha256_file "${STAGE_DIR}/privatedeploy-tray")"
  cat >"${STAGE_DIR}/install-info" <<EOF
format=1
version=${version}
commit=${commit}
installed_at=${timestamp}
artifact_mode=${payload_mode}
artifact_version_source=${version_source}
artifact_commit_source=${commit_source}
payload_sha256=${payload_hash}
core_sha256=${core_hash}
tray_sha256=${tray_hash}
EOF
  chmod 0600 "${STAGE_DIR}/install-info"

  local target_payload="${TARGET_RAW_BIN}"
  [[ "${payload_mode}" == "appimage" ]] && target_payload="${TARGET_APPIMAGE}"
  TX_TARGETS=(
    "${TARGET_LAUNCHER}"
    "${target_payload}"
    "${TARGET_CORE}"
    "${TARGET_TRAY}"
    "${TARGET_DESKTOP}"
    "${TARGET_ICON}"
    "${TARGET_INFO}"
  )
  TX_STAGED=(
    "${STAGE_DIR}/${APP_NAME}"
    "${STAGE_DIR}/${payload_basename}"
    "${STAGE_DIR}/sing-box"
    "${STAGE_DIR}/privatedeploy-tray"
    "${STAGE_DIR}/privatedeploy.desktop"
    "${staged_icon}"
    "${STAGE_DIR}/install-info"
  )
  TX_MODES=(0755 0755 0755 0755 0644 0644 0600)

  prepare_transaction "${timestamp}" "${commit_short}"
  stop_existing_app
  log "==> 原子安装 PrivateDeploy ${version} (${commit_short}, ${payload_mode})"
  install_transaction

  [[ "$(sha256_file "${target_payload}")" == "${payload_hash}" ]] || die "安装后的主程序哈希不匹配"
  [[ "$(sha256_file "${TARGET_CORE}")" == "${core_hash}" ]] || die "安装后的 core 哈希不匹配"
  [[ "$(sha256_file "${TARGET_TRAY}")" == "${tray_hash}" ]] || die "安装后的 tray 哈希不匹配"
  bash -n "${TARGET_LAUNCHER}"

  if [[ "${NO_START}" != "1" ]]; then
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
      die "没有可用桌面会话；设置 PRIVATEDEPLOY_INSTALL_NO_START=1 可仅安装不启动"
    fi
    run_dom_health_check
    stop_health_instance
    start_normal_instance
  else
    warn "已按 PRIVATEDEPLOY_INSTALL_NO_START=1 跳过启动验证"
  fi

  INSTALL_COMMITTED=1
  TRANSACTION_ACTIVE=0

  command_exists update-desktop-database && update-desktop-database "$(dirname "${TARGET_DESKTOP}")" >/dev/null 2>&1 || true
  command_exists gtk-update-icon-cache && gtk-update-icon-cache -f -t "${PD_USER_HOME}/.local/share/icons/hicolor" >/dev/null 2>&1 || true

  log "✅ 安装成功:"
  log "  Launcher: ${TARGET_LAUNCHER}"
  log "  Payload:  ${target_payload}"
  log "  Core:     ${TARGET_CORE}"
  log "  Tray:     ${TARGET_TRAY}"
  log "  Desktop:  ${TARGET_DESKTOP}"
  log "  Version:  ${version} (${commit})"
  log "  Backup:   ${BACKUP_DIR}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
