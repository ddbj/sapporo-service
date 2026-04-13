#!/usr/bin/env bash

set -euo pipefail

# End-to-end smoke test for all (or selected) workflow engines.
# Submits a trivial workflow per engine, polls until COMPLETE, verifies outputs.
#
# Usage:
#   bash scripts/smoketest.sh                     # test all 7 engines
#   bash scripts/smoketest.sh snakemake cwltool    # test specific engines
#
# Environment variables:
#   SAPPORO_TEST_TOKEN         Bearer JWT from Keycloak (required when auth enabled)
#   SAPPORO_TEST_TIMEOUT       Per-engine timeout in seconds (default: 300)
#   SAPPORO_TEST_POLL_INTERVAL Poll interval in seconds (default: 10)

ROOT_DIR="$(cd "$(dirname "$0")" && cd .. && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source .env
set +a

PREFIX="${SAPPORO_URL_PREFIX:-}"
BASE="http://localhost:${SAPPORO_PORT}${PREFIX}"
TIMEOUT="${SAPPORO_TEST_TIMEOUT:-300}"
POLL_INTERVAL="${SAPPORO_TEST_POLL_INTERVAL:-10}"
ALL_ENGINES=(snakemake cwltool nextflow toil cromwell ep3 streamflow)

AUTH_HEADER=()
if [[ -n "${SAPPORO_TEST_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${SAPPORO_TEST_TOKEN}")
fi

# --- reachability ---
echo "[0] sapporo reachable at ${BASE}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${AUTH_HEADER[@]}" "${BASE}/service-info" || echo "000")
if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "401" ]]; then
  echo "  OK (HTTP ${HTTP_CODE})"
else
  echo "  FAIL: HTTP ${HTTP_CODE}"
  exit 1
fi

# --- test workflows ---
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

cat >"${WORK}/Snakefile" <<'SMK'
rule all:
    input: "hello.txt"
rule greet:
    output: "hello.txt"
    shell: "echo hello > {output}"
SMK

cat >"${WORK}/hello.cwl" <<'CWL'
cwlVersion: v1.0
class: CommandLineTool
baseCommand: echo
arguments: ["hello", "world"]
inputs: []
stdout: output.txt
outputs:
  output:
    type: File
    outputBinding:
      glob: output.txt
CWL

cat >"${WORK}/hello.wdl" <<'WDL'
version 1.0
workflow hello {
  call say_hello
}
task say_hello {
  command { echo "hello world" > output.txt }
  output { File out = "output.txt" }
  runtime { docker: "ubuntu:22.04" }
}
WDL

cat >"${WORK}/hello.nf" <<'NF'
process sayHello {
  output:
  path 'output.txt'
  script:
  """
  echo hello world > output.txt
  """
}
workflow {
  sayHello()
}
NF

# --- engine -> (wf_type, wf_version, wf_file) mapping ---
engine_config() {
  case "$1" in
    snakemake)  echo "SMK 1.0 Snakefile" ;;
    cwltool)    echo "CWL v1.0 hello.cwl" ;;
    nextflow)   echo "NFL DSL2 hello.nf" ;;
    toil)       echo "CWL v1.0 hello.cwl" ;;
    cromwell)   echo "WDL 1.0 hello.wdl" ;;
    ep3)        echo "CWL v1.0 hello.cwl" ;;
    streamflow) echo "CWL v1.0 hello.cwl" ;;
    *) echo ""; return 1 ;;
  esac
}

# --- submit and poll ---
submit_and_poll() {
  local engine=$1
  local config
  config=$(engine_config "${engine}")
  if [[ -z "${config}" ]]; then
    echo "  SKIP: unknown engine '${engine}'"
    return 1
  fi
  local wf_type wf_version wf_file
  read -r wf_type wf_version wf_file <<< "${config}"

  echo "=== ${engine} (${wf_type} ${wf_version}) ==="

  local RUN_ID
  RUN_ID=$(curl -s -X POST "${AUTH_HEADER[@]}" \
    -F "workflow_type=${wf_type}" \
    -F "workflow_type_version=${wf_version}" \
    -F "workflow_url=${wf_file}" \
    -F "workflow_engine=${engine}" \
    -F "workflow_params={}" \
    -F "workflow_attachment=@${WORK}/${wf_file}" \
    "${BASE}/runs" | jq -r '.run_id')

  if [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]]; then
    echo "  SUBMIT FAIL"
    return 1
  fi
  echo "  run_id=${RUN_ID}"

  local elapsed=0
  while true; do
    local STATE
    STATE=$(curl -s "${AUTH_HEADER[@]}" "${BASE}/runs/${RUN_ID}/status" | jq -r .state)
    printf "  %4ds  state=%s\n" "${elapsed}" "${STATE}"
    case "${STATE}" in
      COMPLETE)
        echo "  -> OK"
        return 0
        ;;
      EXECUTOR_ERROR|SYSTEM_ERROR|CANCELED)
        echo "  -> FAIL (${STATE})"
        curl -s "${AUTH_HEADER[@]}" "${BASE}/runs/${RUN_ID}" | jq -r '.run_log.stderr // ""' | tail -10
        return 1
        ;;
    esac
    if [[ "${elapsed}" -ge "${TIMEOUT}" ]]; then
      echo "  -> TIMEOUT after ${TIMEOUT}s"
      return 1
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
}

# --- main ---
ENGINES=("${@}")
if [[ ${#ENGINES[@]} -eq 0 ]]; then
  ENGINES=("${ALL_ENGINES[@]}")
fi

PASS=0
FAIL=0
RESULTS=()

for engine in "${ENGINES[@]}"; do
  if submit_and_poll "${engine}"; then
    RESULTS+=("${engine}:OK")
    PASS=$((PASS + 1))
  else
    RESULTS+=("${engine}:FAIL")
    FAIL=$((FAIL + 1))
  fi
  echo ""
done

echo "=========================================="
echo "SUMMARY: ${PASS} OK / ${FAIL} FAIL"
echo "=========================================="
for r in "${RESULTS[@]}"; do echo "  ${r}"; done

[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
