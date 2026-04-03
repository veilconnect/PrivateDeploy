#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"
BUILD_DATA_DIR="${ROOT_DIR}/build/bin/data"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pd-build-data-XXXXXX")"

restore_runtime_data() {
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    return 0
  fi

  shopt -s nullglob
  for path in \
    "user.yaml" \
    "profiles.yaml" \
    "subscribes.yaml" \
    "rulesets.yaml" \
    "plugins.yaml" \
    "scheduledtasks.yaml" \
    ".cache/plugin-list.json" \
    ".cache/ruleset-list.json" \
    "sing-box/config.json" \
    "sing-box/cache.db" \
    "sing-box/cache.db-shm" \
    "sing-box/cache.db-wal" \
    "sing-box/pid.txt"
  do
    if [[ -f "${BACKUP_DIR}/${path}" ]]; then
      mkdir -p "${DATA_DIR}/$(dirname "${path}")"
      mv "${BACKUP_DIR}/${path}" "${DATA_DIR}/${path}"
    fi
  done

  if [[ -d "${BACKUP_DIR}/subscribes" ]]; then
    mkdir -p "${DATA_DIR}/subscribes"
    mv "${BACKUP_DIR}/subscribes/"*.json "${DATA_DIR}/subscribes/" 2>/dev/null || true
  fi

  if [[ -d "${BACKUP_DIR}/cloud" ]]; then
    mkdir -p "${DATA_DIR}/cloud"
    mv "${BACKUP_DIR}/cloud/"*.json "${DATA_DIR}/cloud/" 2>/dev/null || true
  fi

  rm -rf "${BACKUP_DIR}"
}

trap restore_runtime_data EXIT

move_if_present() {
  local relative_path="$1"
  local source_path="${DATA_DIR}/${relative_path}"
  local backup_path="${BACKUP_DIR}/${relative_path}"

  if [[ -f "${source_path}" ]]; then
    mkdir -p "$(dirname "${backup_path}")"
    mv "${source_path}" "${backup_path}"
  fi
}

move_runtime_jsons() {
  local source_dir="$1"
  local backup_dir="$2"
  local pattern="$3"
  mkdir -p "${backup_dir}"
  shopt -s nullglob
  for file in "${source_dir}"/${pattern}; do
    [[ -f "${file}" ]] || continue
    mv "${file}" "${backup_dir}/"
  done
}

purge_runtime_files() {
  local base_dir="$1"
  [[ -d "${base_dir}" ]] || return 0

  rm -f \
    "${base_dir}/user.yaml" \
    "${base_dir}/profiles.yaml" \
    "${base_dir}/subscribes.yaml" \
    "${base_dir}/rulesets.yaml" \
    "${base_dir}/plugins.yaml" \
    "${base_dir}/scheduledtasks.yaml" \
    "${base_dir}/.cache/plugin-list.json" \
    "${base_dir}/.cache/ruleset-list.json" \
    "${base_dir}/sing-box/config.json" \
    "${base_dir}/sing-box/cache.db" \
    "${base_dir}/sing-box/cache.db-shm" \
    "${base_dir}/sing-box/cache.db-wal" \
    "${base_dir}/sing-box/pid.txt"

  if [[ -d "${base_dir}/subscribes" ]]; then
    find "${base_dir}/subscribes" -maxdepth 1 -type f -name '*.json' -delete
  fi

  if [[ -d "${base_dir}/cloud" ]]; then
    find "${base_dir}/cloud" -maxdepth 1 -type f -name '*.json' ! -name '*.example.json' -delete
  fi
}

for path in \
  "user.yaml" \
  "profiles.yaml" \
  "subscribes.yaml" \
  "rulesets.yaml" \
  "plugins.yaml" \
  "scheduledtasks.yaml" \
  ".cache/plugin-list.json" \
  ".cache/ruleset-list.json" \
  "sing-box/config.json" \
  "sing-box/cache.db" \
  "sing-box/cache.db-shm" \
  "sing-box/cache.db-wal" \
  "sing-box/pid.txt"
do
  move_if_present "${path}"
done

if [[ -d "${DATA_DIR}/subscribes" ]]; then
  move_runtime_jsons "${DATA_DIR}/subscribes" "${BACKUP_DIR}/subscribes" "*.json"
fi

if [[ -d "${DATA_DIR}/cloud" ]]; then
  mkdir -p "${BACKUP_DIR}/cloud"
  shopt -s nullglob
  for file in "${DATA_DIR}/cloud/"*.json; do
    [[ -f "${file}" ]] || continue
    case "${file}" in
      *.example.json) ;;
      *) mv "${file}" "${BACKUP_DIR}/cloud/" ;;
    esac
  done
fi

purge_runtime_files "${BUILD_DATA_DIR}"

exec "$@"
