#!/usr/bin/env bash

set -euo pipefail

# Minimal end-to-end smoke test: submit a trivial snakemake workflow,
# poll until COMPLETE, verify outputs list.
#
# Usage: bash scripts/smoketest.sh
#
# Environment variables:
#   SAPPORO_TEST_TOKEN         Bearer JWT from Keycloak (required when auth enabled)
#   SAPPORO_TEST_TIMEOUT       Overall timeout in seconds (default: 600)
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

BASE="http://localhost:${SAPPORO_PORT}"
TIMEOUT="${SAPPORO_TEST_TIMEOUT:-600}"
POLL_INTERVAL="${SAPPORO_TEST_POLL_INTERVAL:-10}"

AUTH_HEADER=()
if [[ -n "${SAPPORO_TEST_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${SAPPORO_TEST_TOKEN}")
fi

echo "[1] sapporo reachable"
curl -sf --max-time 5 "${AUTH_HEADER[@]}" "${BASE}/service-info" >/dev/null \
  || { echo "  FAIL: ${BASE}/service-info unreachable"; exit 1; }
echo "  OK"

echo "[2] prepare trivial snakemake workflow"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

cat >"${WORK}/Snakefile" <<'SMK'
rule all:
    input: "hello.txt"

rule greet:
    output: "hello.txt"
    shell: "echo hello > {output}"
SMK

cat >"${WORK}/params.json" <<'JSON'
{}
JSON

echo "[3] submit run"
RUN_ID=$(curl -sf -X POST "${AUTH_HEADER[@]}" \
  -F "workflow_type=SMK" \
  -F "workflow_type_version=1.0" \
  -F "workflow_url=Snakefile" \
  -F "workflow_engine=snakemake" \
  -F "workflow_params=@${WORK}/params.json" \
  -F "workflow_attachment=@${WORK}/Snakefile" \
  "${BASE}/runs" | jq -r '.run_id')
if [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]]; then
  echo "  FAIL: no run_id returned"
  exit 1
fi
echo "  run_id=${RUN_ID}"

echo "[4] poll until COMPLETE (timeout ${TIMEOUT}s)"
elapsed=0
while true; do
  STATE=$(curl -sf "${AUTH_HEADER[@]}" "${BASE}/runs/${RUN_ID}/status" | jq -r .state)
  printf "  %4ds  state=%s\n" "${elapsed}" "${STATE}"
  case "${STATE}" in
    COMPLETE)
      break
      ;;
    EXECUTOR_ERROR|SYSTEM_ERROR|CANCELED)
      echo "  FAIL: state=${STATE}"
      curl -sf "${AUTH_HEADER[@]}" "${BASE}/runs/${RUN_ID}" | jq -r '.run_log.stderr // ""' | tail -20
      exit 1
      ;;
  esac
  if [[ "${elapsed}" -ge "${TIMEOUT}" ]]; then
    echo "  FAIL: timed out after ${TIMEOUT}s"
    exit 1
  fi
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done

echo "[5] verify outputs list contains hello.txt"
OUTPUTS_JSON=$(curl -sf "${AUTH_HEADER[@]}" "${BASE}/runs/${RUN_ID}/outputs")
if echo "${OUTPUTS_JSON}" | jq -r '.outputs[].file_name' | grep -q "^hello.txt$"; then
  echo "  OK"
else
  echo "  FAIL: hello.txt not found in outputs"
  echo "${OUTPUTS_JSON}" | jq .
  exit 1
fi

echo ""
echo "smoketest passed (run_id=${RUN_ID})"
