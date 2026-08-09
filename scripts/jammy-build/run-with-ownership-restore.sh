#!/usr/bin/env bash
# Run a Jammy container build and return bind-mounted build outputs to the
# owner of /repo. Docker otherwise leaves root-owned dist/build/node_modules
# behind on the host, making the next non-container build fail with EACCES.

set -euo pipefail

if (( $# == 0 )); then
  echo "ERROR: missing container build command" >&2
  exit 2
fi

REPO_OWNER_UID="$(stat -c %u /repo)"
REPO_OWNER_GID="$(stat -c %g /repo)"
[[ "${REPO_OWNER_UID}" =~ ^[0-9]+$ && "${REPO_OWNER_GID}" =~ ^[0-9]+$ ]] || {
  echo "ERROR: unable to determine numeric /repo owner" >&2
  exit 1
}

restore_host_ownership() {
  local path
  local failed=0
  for path in /repo/frontend/dist /repo/frontend/node_modules /repo/build; do
    if [[ -L "${path}" ]]; then
      echo "ERROR: refusing to chown symlinked build path: ${path}" >&2
      failed=1
    elif [[ -e "${path}" && ! -d "${path}" ]]; then
      echo "ERROR: build path is not a directory: ${path}" >&2
      failed=1
    elif [[ -d "${path}" ]] && \
         ! chown -R -h -P --preserve-root --from=0:0 -- \
           "${REPO_OWNER_UID}:${REPO_OWNER_GID}" "${path}"; then
      failed=1
    fi
  done
  return "${failed}"
}

on_exit() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  restore_host_ownership || cleanup_status=$?
  if (( cleanup_status != 0 )); then
    echo "ERROR: failed to restore host ownership of build outputs" >&2
    (( status != 0 )) || status="${cleanup_status}"
  fi
  exit "${status}"
}
trap on_exit EXIT

"$@"
