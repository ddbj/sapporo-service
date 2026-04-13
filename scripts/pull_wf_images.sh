#!/usr/bin/env bash

set -euo pipefail

# Pull workflow engine container images to Slurm compute nodes.
#
# Usage:
#   bash scripts/pull_wf_images.sh                 # local + all slurm nodes (sinfo)
#   bash scripts/pull_wf_images.sh --local-only    # frontend node only
#   bash scripts/pull_wf_images.sh --node <name>   # one specific node via ssh
#
# Remote nodes are pulled in parallel; per-node logs go under logs/.

ROOT_DIR="$(cd "$(dirname "$0")" && cd .. && pwd)"
cd "${ROOT_DIR}"
mkdir -p logs

IMAGES=(
  "quay.io/commonwl/cwltool:3.1.20260108082145"
  "nextflow/nextflow:25.10.4"
  "quay.io/ucsc_cgl/toil:9.1.1"
  "ghcr.io/sapporo-wes/cromwell-with-docker:92"
  "snakemake/snakemake:v9.16.3"
  "ghcr.io/tom-tan/ep3:v1.7.0"
  "alphaunito/streamflow:0.2.0.dev14"
)

mode="all"
specific_node=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-only)
      mode="local"
      shift
      ;;
    --node)
      mode="single"
      specific_node="${2:-}"
      if [[ -z "${specific_node}" ]]; then
        echo "ERROR: --node requires a node name" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      sed -n '3,11p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

function pull_local() {
  # Rootless podman needs a systemd user session to persist /run/user/$UID.
  # enable-linger ensures it survives after logout (idempotent).
  loginctl enable-linger
  local failed=0
  for image in "${IMAGES[@]}"; do
    echo "[local] pulling ${image}"
    if ! podman pull "${image}"; then
      echo "[local] FAILED: ${image}" >&2
      failed=$((failed + 1))
    fi
  done
  return "${failed}"
}

function pull_remote() {
  local node=$1
  local log="logs/pull-wf-images-${node}.log"
  echo "[${node}] pulling in background (log=${log})"
  {
    echo "=== pull_wf_images.sh on ${node} at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==="
    # Rootless podman needs a systemd user session to persist /run/user/$UID.
    # enable-linger ensures it survives after logout (idempotent).
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${node}" "loginctl enable-linger" || true
    for image in "${IMAGES[@]}"; do
      echo "--- pulling ${image} ---"
      if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "${node}" "podman pull ${image}"; then
        echo "FAILED: ${image}"
      fi
    done
  } >"${log}" 2>&1 &
}

case "${mode}" in
  local)
    pull_local
    ;;
  single)
    pull_remote "${specific_node}"
    wait
    ;;
  all)
    pull_local || true
    # Enumerate Slurm compute nodes via sinfo, skip the frontend.
    nodes=$(sinfo -h -N -o "%N" | sort -u | grep -v "^$(hostname)$" || true)
    if [[ -z "${nodes}" ]]; then
      echo "No remote nodes discovered via sinfo; skipping remote pulls."
    else
      for node in ${nodes}; do
        pull_remote "${node}"
      done
      wait
    fi
    ;;
esac

echo "done"
