#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/output/cloud-tests"
TS="$(date +%Y%m%d_%H%M%S)"
BASE_TMP="/tmp/pd-cloud-vultr-do-${TS}"
API_REPORT_JSON="${OUT_DIR}/vultr-do-api-smoke-${TS}.json"
CLOUD_REPORT_JSON="${OUT_DIR}/vultr-do-provider-smoke-${TS}.json"
SUMMARY_MD="${OUT_DIR}/vultr-do-summary-${TS}.md"

mkdir -p "${OUT_DIR}" "${BASE_TMP}"

if [[ -z "${VULTR_API_KEY:-}" ]]; then
  echo "VULTR_API_KEY is required"
  exit 2
fi
if [[ -z "${DIGITALOCEAN_API_KEY:-}" ]]; then
  echo "DIGITALOCEAN_API_KEY is required"
  exit 2
fi

# Disable proxy for this script only, so we don't depend on local 7890 proxy.
export HTTPS_PROXY=
export HTTP_PROXY=
export ALL_PROXY=
export NO_PROXY="*"

run_curl_probe() {
  local name="$1"
  local url="$2"
  local header="$3"
  local body_file="${BASE_TMP}/${name}.body.json"
  local err_file="${BASE_TMP}/${name}.err.log"

  local metric
  metric="$(curl --noproxy '*' -sS -o "${body_file}" \
    -w '{"http_code":"%{http_code}","time_namelookup":"%{time_namelookup}","time_connect":"%{time_connect}","time_starttransfer":"%{time_starttransfer}","time_total":"%{time_total}"}' \
    -H "${header}" "${url}" 2>"${err_file}" || true)"
  if ! jq -e . >/dev/null 2>&1 <<<"${metric}"; then
    metric='{"http_code":"000","time_namelookup":"0","time_connect":"0","time_starttransfer":"0","time_total":"0"}'
  fi

  jq -n \
    --arg name "${name}" \
    --arg url "${url}" \
    --argjson metric "${metric}" \
    --arg body "$(head -c 300 "${body_file}" 2>/dev/null || true)" \
    --arg curl_error "$(head -c 300 "${err_file}" 2>/dev/null || true)" \
    '{
      name: $name,
      url: $url,
      metric: $metric,
      body_preview: $body,
      curl_error: $curl_error
    }'
}

api_rows="$(
  {
    run_curl_probe vultr_account https://api.vultr.com/v2/account "Authorization: Bearer ${VULTR_API_KEY}"
    run_curl_probe vultr_regions https://api.vultr.com/v2/regions "Authorization: Bearer ${VULTR_API_KEY}"
    run_curl_probe do_account https://api.digitalocean.com/v2/account "Authorization: Bearer ${DIGITALOCEAN_API_KEY}"
    run_curl_probe do_regions https://api.digitalocean.com/v2/regions "Authorization: Bearer ${DIGITALOCEAN_API_KEY}"
  } | jq -s '.'
)"

jq -n --arg ts "${TS}" --argjson rows "${api_rows}" '{generatedAt: $ts, checks: $rows}' > "${API_REPORT_JSON}"

(
  cd "${ROOT_DIR}"
  GOCACHE=/tmp/pd-gocache \
  PRIVATEDEPLOY_BASE_PATH="${BASE_TMP}" \
  VULTR_API_KEY="${VULTR_API_KEY}" \
  DIGITALOCEAN_API_KEY="${DIGITALOCEAN_API_KEY}" \
  go run ./tmp/cloud_online_check --providers vultr,digitalocean --timeout-sec 45 > "${CLOUD_REPORT_JSON}"
)

{
  echo "# Vultr + DigitalOcean Full Smoke (${TS})"
  echo
  echo "## API Probe"
  jq -r '.checks[] | "- \(.name): code=\(.metric.http_code // "n/a"), ttfb=\(.metric.time_starttransfer // "n/a")s, total=\(.metric.time_total // "n/a")s"' "${API_REPORT_JSON}"
  echo
  echo "## Provider Flow (SDK)"
  jq -r '.providers[] | "- \(.provider): liveApiOk=\(.liveApiOk), regions=\(.regions.count), plans=\(.plans.count), availability=\(.availability.count), instances=\(.instances.count), err=\(.instances.error // "-")"' "${CLOUD_REPORT_JSON}"
  echo
  echo "## Output"
  echo "- ${API_REPORT_JSON}"
  echo "- ${CLOUD_REPORT_JSON}"
} > "${SUMMARY_MD}"

echo "API report     : ${API_REPORT_JSON}"
echo "Provider report: ${CLOUD_REPORT_JSON}"
echo "Summary        : ${SUMMARY_MD}"
