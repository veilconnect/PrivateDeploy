#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUD_DIR="${ROOT_DIR}/data/cloud"
OUT_DIR="${ROOT_DIR}/output/cloud-tests"
TS="$(date +%Y%m%d_%H%M%S)"
REPORT_JSON="${OUT_DIR}/all-cloud-online-${TS}.json"
REPORT_MD="${OUT_DIR}/manual-intervention-${TS}.md"

mkdir -p "${CLOUD_DIR}" "${OUT_DIR}"

write_example() {
  local provider="$1"
  local path="${CLOUD_DIR}/${provider}-config.example.json"
  if [[ -f "${path}" ]]; then
    return 0
  fi

  case "${provider}" in
    hetzner|linode|scaleway)
      cat >"${path}" <<EOF
{
  "provider": "${provider}",
  "apiKey": "<API_KEY>",
  "defaultRegion": "",
  "defaultPlan": "",
  "extra": {}
}
EOF
      ;;
    upcloud)
      cat >"${path}" <<EOF
{
  "provider": "upcloud",
  "apiKey": "<username>:<password>",
  "defaultRegion": "",
  "defaultPlan": "",
  "extra": {
    "templateStorage": ""
  }
}
EOF
      ;;
    contabo)
      cat >"${path}" <<EOF
{
  "provider": "contabo",
  "apiKey": "<client_id>|<client_secret>|<username>|<password>",
  "defaultRegion": "",
  "defaultPlan": "",
  "extra": {}
}
EOF
      ;;
    oracle)
      cat >"${path}" <<EOF
{
  "provider": "oracle",
  "apiKey": "DEFAULT",
  "defaultRegion": "",
  "defaultPlan": "VM.Standard.E2.1.Micro",
  "extra": {
    "compartmentId": "<ocid1.compartment...>",
    "subnetId": "<ocid1.subnet...>",
    "availabilityDomain": "",
    "imageId": "",
    "profile": "DEFAULT"
  }
}
EOF
      ;;
    vultr|digitalocean)
      cat >"${path}" <<EOF
{
  "provider": "${provider}",
  "apiKey": "<API_KEY>",
  "defaultRegion": "",
  "defaultPlan": "",
  "extra": {}
}
EOF
      ;;
  esac
}

for p in vultr digitalocean hetzner linode scaleway upcloud contabo oracle; do
  write_example "${p}"
done

(
  cd "${ROOT_DIR}"
  go run ./tmp/cloud_online_check --timeout-sec 45 >"${REPORT_JSON}"
)

{
  echo "# Cloud Manual Intervention Checklist (${TS})"
  echo
  echo "Generated from: ${REPORT_JSON}"
  echo
  echo "## Online Test Summary"
  jq -r '.summary | to_entries[] | "- \(.key): \(.value)"' "${REPORT_JSON}"
  echo
  echo "## Providers"
  jq -r '.providers[] | "- \(.provider): hasKey=\(.hasKey), liveApiOk=\(.liveApiOk), instancesError=\(.instances.error // "-")"' "${REPORT_JSON}"
  echo
  echo "## Must-Human-Intervene"

  missing_count="$(jq '[.providers[] | select(.hasKey == false)] | length' "${REPORT_JSON}")"
  if [[ "${missing_count}" -gt 0 ]]; then
    echo "- Register/login and create API keys for missing providers:"
    jq -r '.providers[] | select(.hasKey == false) | "  - \(.provider)"' "${REPORT_JSON}"
  else
    echo "- No missing provider keys."
  fi

  vultr_err="$(jq -r '.providers[] | select(.provider=="vultr") | .instances.error // ""' "${REPORT_JSON}")"
  if [[ "${vultr_err}" == *"expired"* || "${vultr_err}" == *"Unauthorized"* ]]; then
    echo "- Vultr API key appears expired/unauthorized: revoke and create a new key."
  fi

  if jq -e '.providers[] | select(.provider=="oracle" and .hasKey==true)' >/dev/null "${REPORT_JSON}"; then
    if ! command -v oci >/dev/null 2>&1; then
      echo "- Oracle key exists but local OCI CLI is missing: install/configure oci CLI."
    fi
  else
    echo "- Oracle requires BOTH API access setup and local OCI CLI/profile configuration."
  fi

  echo
  echo "## Local Example Config Files"
  for p in vultr digitalocean hetzner linode scaleway upcloud contabo oracle; do
    echo "- data/cloud/${p}-config.example.json"
  done
} >"${REPORT_MD}"

echo "JSON report: ${REPORT_JSON}"
echo "Checklist : ${REPORT_MD}"

