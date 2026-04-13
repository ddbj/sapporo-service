#!/usr/bin/env bash

set -euo pipefail

# Sapporo NIG healthcheck: container / API / slurmrestd / Keycloak.
# Usage: bash scripts/healthcheck.sh
# Exits 1 if any check fails.

ROOT_DIR="$(cd "$(dirname "$0")" && cd .. && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run 'cp env.<env> .env' first." >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source .env
set +a

PASS=0
FAIL=0

function pass() {
  echo "  OK: $1"
  PASS=$((PASS + 1))
}
function fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

echo "[1] sapporo container status"
CONTAINER="sapporo-service-${SAPPORO_ENV}"
if podman inspect --format='{{.State.Status}}' "${CONTAINER}" 2>/dev/null | grep -q running; then
  pass "${CONTAINER} running"
else
  fail "${CONTAINER} not running"
fi

echo "[2] sapporo /service-info"
if curl -sf --max-time 5 "http://localhost:${SAPPORO_PORT}/service-info" >/dev/null; then
  pass "/service-info on localhost:${SAPPORO_PORT}"
else
  fail "/service-info on localhost:${SAPPORO_PORT} unreachable"
fi

echo "[3] slurmrestd diag"
if [[ -f sapporo_config/slurm.env ]]; then
  # shellcheck source=/dev/null
  source sapporo_config/slurm.env
  if curl -sf --max-time 5 \
    -H "X-SLURM-USER-TOKEN: ${SLURM_JWT}" \
    "http://${SLURM_MASTER_NODE_IP}:${SLURM_MASTER_NODE_PORT}/slurm/v0.0.39/diag" \
    >/dev/null; then
    pass "slurmrestd at ${SLURM_MASTER_NODE_IP}:${SLURM_MASTER_NODE_PORT}"
  else
    fail "slurmrestd at ${SLURM_MASTER_NODE_IP}:${SLURM_MASTER_NODE_PORT} unreachable (JWT expired?)"
  fi
else
  fail "sapporo_config/slurm.env missing (run 'bash scripts/update_slurm_env.sh')"
fi

echo "[4] Keycloak OIDC"
IDP_URL=$(jq -r '.external_config.idp_url' sapporo_config/auth_config.json)
if curl -sf --max-time 5 "${IDP_URL}/.well-known/openid-configuration" >/dev/null; then
  pass "Keycloak ${IDP_URL}"
else
  fail "Keycloak ${IDP_URL} unreachable"
fi

echo ""
echo "  ${PASS} OK / ${FAIL} FAIL"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
