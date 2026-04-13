#!/usr/bin/env bash

set -euo pipefail

# =========================================
# Sapporo run.sh for NIG Slurm Environment (dev/staging/prod)
# - Submits jobs to slurmrestd via REST API (not sbatch)
# - Runs workflow engines in rootless podman on Slurm compute nodes
# - outputs.json is generated on the worker (sapporo-cli unavailable there)
# - RO-Crate is generated afterwards in this sapporo container
# Supported engines: cwltool, nextflow, toil, cromwell, snakemake, ep3, streamflow
# =========================================

# shellcheck source=/dev/null
source /app/sapporo_config/slurm.env

# ==============================================================
# Slurm REST API functions
# ==============================================================

SLURM_API_URL="http://${SLURM_MASTER_NODE_IP}:${SLURM_MASTER_NODE_PORT}"
SLURM_API_VERSION="v0.0.39"

function slurm_submit_job() {
  local job_json=$1
  local response
  response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "X-SLURM-USER-TOKEN: ${SLURM_JWT}" \
    "${SLURM_API_URL}/slurm/${SLURM_API_VERSION}/job/submit" \
    -d @"${job_json}")

  local errors
  errors=$(echo "${response}" | jq -r '.errors | length')
  if [[ "${errors}" != "0" ]]; then
    echo "slurm REST API error: ${response}" >&2
    return 1
  fi

  local job_id
  job_id=$(echo "${response}" | jq -r '.job_id')
  echo "${job_id}"
}

function slurm_cancel_job() {
  local job_id=$1
  curl -s -X DELETE \
    -H "X-SLURM-USER-TOKEN: ${SLURM_JWT}" \
    "${SLURM_API_URL}/slurm/${SLURM_API_VERSION}/job/${job_id}"
}

function wait_for_slurm_job() {
  if [[ ! -f "${slurm_jobid}" ]]; then
    return 0
  fi

  local job_id
  job_id=$(cat "${slurm_jobid}")

  while true; do
    local job_state
    job_state=$(curl -s --max-time 10 \
      -H "X-SLURM-USER-TOKEN: ${SLURM_JWT}" \
      "${SLURM_API_URL}/slurm/${SLURM_API_VERSION}/job/${job_id}" \
      2>/dev/null \
      | jq -r '.jobs[0].job_state[0]' 2>/dev/null \
      || echo "POLL_ERROR")

    case "${job_state}" in
      COMPLETED)
        break
        ;;
      FAILED|NODE_FAIL|TIMEOUT|OUT_OF_MEMORY|PREEMPTED|BOOT_FAIL|DEADLINE|CANCELLED)
        local current_state
        current_state=$(cat "${state}" 2>/dev/null || echo "")
        case "${current_state}" in
          COMPLETE|EXECUTOR_ERROR|CANCELED|SYSTEM_ERROR)
            break
            ;;
        esac
        if [[ "${job_state}" == "CANCELLED" ]]; then
          cancel_by_request
        else
          executor_error 1
        fi
        ;;
      *)
        # PENDING, RUNNING, CONFIGURING, or transient POLL_ERROR
        sleep 120 || true
        ;;
    esac
  done
}

# ==============================================================
# Slurm script generation
# ==============================================================

function generate_slurm_script() {
  local main_cmd_local=$1
  local main_label=$2
  local post_cmd=${3:-}

  cat <<'SLURM_SCRIPT_HEREDOC' >"${slurm_script}"
#!/bin/bash
set -euo pipefail

function executor_error() {
  local original_exit_code=${1:-$?}
  echo "${original_exit_code}" >__EXIT_CODE__
  date -u +"%Y-%m-%dT%H:%M:%S" >__END_TIME__
  echo "EXECUTOR_ERROR" >__STATE__
  exit "${original_exit_code}"
}

# Worker-side reimplementation of generate_outputs_list using find + jq.
# sapporo-cli is not installed on Slurm compute nodes.
function generate_outputs_list() {
  local run_dir="__RUN_DIR__"
  local run_id
  run_id=$(basename "${run_dir}")
  local runtime_info="${run_dir}/runtime_info.json"
  local outputs_dir="${run_dir}/outputs"
  local outputs_json="${run_dir}/outputs.json"

  local base_url
  base_url=$(jq -r '.base_url' "${runtime_info}")

  find "${outputs_dir}" -type f | sort | sed "s|^${outputs_dir}/||" | \
    jq -R -s --arg base_url "${base_url}" --arg run_id "${run_id}" '
      split("\n") | map(select(length > 0)) | map({
        "file_name": .,
        "file_url": "\($base_url)/runs/\($run_id)/outputs/\(.)"
      })
    ' >"${outputs_json}"
}

# Start running
echo "RUNNING" >__STATE__
date -u +"%Y-%m-%dT%H:%M:%S" >__START_TIME__

# Ensure rootless podman socket is available for engines that spawn
# sub-containers. On Slurm worker nodes /run/user/$UID/podman/podman.sock
# may not exist because there is no interactive login session.
_SAPPORO_PODMAN_SOCK="/tmp/sapporo-podman-$(id -u).sock"
if [[ -S "/run/user/$(id -u)/podman/podman.sock" ]]; then
  _SAPPORO_PODMAN_SOCK="/run/user/$(id -u)/podman/podman.sock"
else
  rm -f "${_SAPPORO_PODMAN_SOCK}"
  podman system service --time 0 "unix://${_SAPPORO_PODMAN_SOCK}" &
  _SAPPORO_SVC_PID=$!
  for _i in 1 2 3 4 5; do
    [[ -S "${_SAPPORO_PODMAN_SOCK}" ]] && break
    sleep 1
  done
fi
export _SAPPORO_PODMAN_SOCK

# Main workflow command
echo "=== [__MAIN_LABEL__] Started ===" >>__STDERR__
__MAIN_CMD__ || {
  echo "=== [__MAIN_LABEL__] Failed (exit_code=$?) ===" >>__STDERR__
  executor_error
}
echo "=== [__MAIN_LABEL__] Completed ===" >>__STDERR__

# Engine-specific post-processing (outputs copy, metadata extraction, etc.)
__POST_CMD__

# Generate outputs list
generate_outputs_list

# Complete
echo 0 >__EXIT_CODE__
date -u +"%Y-%m-%dT%H:%M:%S" >__END_TIME__
echo "COMPLETE" >__STATE__
SLURM_SCRIPT_HEREDOC

  # Replace placeholders using SOH control character (0x01) as delimiter
  # to avoid conflicts with any printable character in variable values.
  # Escape sed replacement special chars: & (backreference) and \ (escape).
  local d=$'\x01'
  local esc_main="${main_cmd_local//&/\\&}"
  local esc_post="${post_cmd//&/\\&}"
  sed -i "s${d}__RUN_DIR__${d}${run_dir}${d}g" "${slurm_script}"
  sed -i "s${d}__STATE__${d}${state}${d}g" "${slurm_script}"
  sed -i "s${d}__STDERR__${d}${stderr}${d}g" "${slurm_script}"
  sed -i "s${d}__START_TIME__${d}${start_time}${d}g" "${slurm_script}"
  sed -i "s${d}__END_TIME__${d}${end_time}${d}g" "${slurm_script}"
  sed -i "s${d}__EXIT_CODE__${d}${exit_code}${d}g" "${slurm_script}"
  sed -i "s${d}__MAIN_LABEL__${d}${main_label}${d}g" "${slurm_script}"
  sed -i "s${d}__MAIN_CMD__${d}${esc_main}${d}g" "${slurm_script}"
  sed -i "s${d}__POST_CMD__${d}${esc_post}${d}g" "${slurm_script}"

  if grep -qP '__[A-Z_]{3,}__' "${slurm_script}"; then
    echo "BUG: unreplaced placeholders in ${slurm_script}:" >&2
    grep -nP '__[A-Z_]{3,}__' "${slurm_script}" >&2
    executor_error 1
  fi

  chmod +x "${slurm_script}"
}

function generate_slurm_job_json() {
  local script_content
  script_content=$(cat "${slurm_script}")

  # nice is passed via #SBATCH directive because slurmrestd 24.05.x crashes
  # (SIGABRT) when "nice" is in the JSON body.
  local nice_value=0
  nice_value=$(jq -r '.workflow_engine_parameters.nice // "0"' "${run_request}" 2>/dev/null || echo "0")
  if [[ "${nice_value}" -gt 0 ]]; then
    script_content=$(echo "${script_content}" | sed "1a\\#SBATCH --nice=${nice_value}")
  fi

  jq -n \
    --arg script "${script_content}" \
    --arg name "sapporo_${wf_engine}_$(basename "${run_dir}")" \
    --arg cwd "${exe_dir}" \
    --arg partition "${SLURM_PARTITION}" \
    --argjson cpus "${SLURM_CPUS_PER_TASK}" \
    --argjson mem "${SLURM_MEMORY_PER_CPU}" \
    '{
      "script": $script,
      "job": {
        "name": $name,
        "partition": $partition,
        "cpus_per_task": $cpus,
        "memory_per_cpu": {
          "number": $mem,
          "set": true
        },
        "current_working_directory": $cwd,
        "environment": ["PATH=/usr/bin:/bin:/usr/local/bin"]
      }
    }' >"${slurm_job_json}"
}

function submit_engine_job() {
  generate_slurm_job_json
  echo "${main_cmd}" >"${cmd}"

  local job_id
  if ! job_id=$(slurm_submit_job "${slurm_job_json}"); then
    executor_error 1
  fi
  if [[ -z "${job_id}" || "${job_id}" == "null" ]]; then
    executor_error 1
  fi
  echo "${job_id}" >"${slurm_jobid}"
}

# ==============================================================
# Main dispatch
# ==============================================================

function run_wf() {
  check_canceling

  local function_name="run_${wf_engine}"
  if [[ "$(type -t "${function_name}")" == "function" ]]; then
    "${function_name}"
  else
    desc_error
  fi

  wait_for_slurm_job

  # RO-Crate is generated in the sapporo container (not on the slurm
  # worker where sapporo-cli is unavailable).
  local current_state
  current_state=$(cat "${state}" 2>/dev/null || echo "")
  if [[ "${current_state}" == "COMPLETE" ]]; then
    generate_ro_crate
  fi

  exit 0
}

function generate_ro_crate() {
  sapporo-cli generate-ro-crate "${run_dir}" 2>>"${stderr}" \
    || echo '{"@error": "RO-Crate generation failed. Check stderr.log for details."}' >"${ro_crate}"
}

# ==============================================================
# Engine functions
# ==============================================================
# Each run_<engine>() builds `main_cmd`: a single-line string that runs the
# engine container via `podman run --rm --userns=keep-id` on the slurm
# worker. run_dir is bind-mounted with the same host-absolute path so that
# nested engine subcontainers (cwltool's DockerRequirement, nextflow's
# process.container, etc.) resolve paths identically.
#
# For engines that need per-run post-processing (snakemake output copy,
# cromwell metadata extraction), a small shell script is written into
# ${exe_dir} and passed as ${post_cmd} to generate_slurm_script.

function run_cwltool() {
  local container="quay.io/commonwl/cwltool:3.1.20260108082145"
  main_cmd="podman run --rm --userns=keep-id -v \${_SAPPORO_PODMAN_SOCK}:/var/run/docker.sock -e DOCKER_HOST=unix:///var/run/docker.sock -v /tmp:/tmp -v ${run_dir}:${run_dir} ${extra_podman_args_str} -w ${exe_dir} ${container} --outdir ${outputs_dir} ${wf_engine_params} ${wf_url} ${wf_params} 1>>${stdout} 2>>${stderr}"
  generate_slurm_script "${main_cmd}" "cwltool"
  submit_engine_job
}

function run_nextflow() {
  local container="nextflow/nextflow:25.10.4"
  # Store NXF_HOME inside the run_dir so pipeline assets stay on the shared
  # filesystem visible to both sapporo container and slurm worker.
  local nxf_home="${run_dir}/nxf_home"
  mkdir -p "${nxf_home}"
  local nf_config="${exe_dir}/sapporo.config"
  cat >"${nf_config}" <<'NFCFG'
docker.envWhitelist = 'DOCKER_API_VERSION'
NFCFG
  main_cmd="podman run --rm --userns=keep-id -v \${_SAPPORO_PODMAN_SOCK}:/var/run/docker.sock -e DOCKER_HOST=unix:///var/run/docker.sock -e NXF_HOME=${nxf_home} -e NXF_ASSETS=${nxf_home}/assets -v ${run_dir}:${run_dir} ${extra_podman_args_str} -w ${exe_dir} ${container} nextflow run ${wf_url} -c ${nf_config} ${wf_engine_params} -params-file ${wf_params} --outdir ${outputs_dir} -work-dir ${exe_dir} 1>>${stdout} 2>>${stderr}"
  generate_slurm_script "${main_cmd}" "nextflow"
  submit_engine_job
}

function run_toil() {
  local container="quay.io/ucsc_cgl/toil:9.1.1"
  main_cmd="podman run --rm --userns=keep-id -v \${_SAPPORO_PODMAN_SOCK}:/var/run/docker.sock -e DOCKER_HOST=unix:///var/run/docker.sock -v ${run_dir}:${run_dir} -e TOIL_WORKDIR=${exe_dir} ${extra_podman_args_str} -w ${exe_dir} ${container} toil-cwl-runner --outdir ${outputs_dir} ${wf_engine_params} ${wf_url} ${wf_params} 1>>${stdout} 2>>${stderr}"
  generate_slurm_script "${main_cmd}" "toil"
  submit_engine_job
}

function run_cromwell() {
  local container="ghcr.io/sapporo-wes/cromwell-with-docker:92"
  main_cmd="podman run --rm --userns=keep-id -v \${_SAPPORO_PODMAN_SOCK}:/var/run/docker.sock -e DOCKER_HOST=unix:///var/run/docker.sock -v /tmp:/tmp -v ${run_dir}:${run_dir} ${extra_podman_args_str} -w ${exe_dir} ${container} run ${wf_engine_params} ${wf_url} -i ${wf_params} -m ${exe_dir}/metadata.json 1>>${stdout} 2>>${stderr}"

  # Post: copy output files listed in cromwell's metadata.json into outputs/.
  local post_script="${exe_dir}/.cromwell_post.sh"
  cat >"${post_script}" <<CROMWELL_POST_EOF
#!/bin/bash
set -uo pipefail
if [[ -f "${exe_dir}/metadata.json" ]]; then
  while read -r output_file; do
    if [[ -n "\${output_file}" && -f "\${output_file}" ]]; then
      cp "\${output_file}" "${outputs_dir}/" || true
    fi
  done < <(jq -r '.outputs | to_entries[] | .value // empty' "${exe_dir}/metadata.json" 2>>"${stderr}")
else
  echo "Warning: metadata.json not found" >>"${stderr}"
fi
CROMWELL_POST_EOF
  chmod +x "${post_script}"

  generate_slurm_script "${main_cmd}" "cromwell" "bash ${post_script}"
  submit_engine_job
}

function run_snakemake() {
  local wf_url_local
  if [[ "${wf_url}" == http://* ]] || [[ "${wf_url}" == https://* ]]; then
    wf_url_local="${exe_dir}/$(basename "${wf_url}")"
    curl -fsSL -o "${wf_url_local}" "${wf_url}" || { executor_error $?; }
  elif [[ "${wf_url}" == /* ]]; then
    wf_url_local="${wf_url}"
  else
    wf_url_local="${exe_dir}/${wf_url}"
  fi

  local container="snakemake/snakemake:v9.16.3"
  main_cmd="podman run --rm --userns=keep-id -e HOME=/tmp -v ${run_dir}:${run_dir} ${extra_podman_args_str} -w ${exe_dir} ${container} bash -c \"snakemake --workflow-profile none ${wf_engine_params} --configfile ${wf_params} --snakefile ${wf_url_local} && snakemake --workflow-profile none --configfile ${wf_params} --snakefile ${wf_url_local} --summary 2>/dev/null | tail -n +2 | cut -f 1 > ${exe_dir}/.snakemake_outputs\" 1>>${stdout} 2>>${stderr}"

  # Post: copy snakemake outputs listed in .snakemake_outputs.
  local post_script="${exe_dir}/.snakemake_post.sh"
  cat >"${post_script}" <<SNAKEMAKE_POST_EOF
#!/bin/bash
set -uo pipefail
if [[ -f "${exe_dir}/.snakemake_outputs" ]]; then
  while read -r file_path; do
    [[ -z "\${file_path}" ]] && continue
    case "\${file_path}" in
      *..*|/*)
        echo "Warning: skip suspicious output path: \${file_path}" >>"${stderr}"
        continue
        ;;
    esac
    mkdir -p "${outputs_dir}/\$(dirname "\${file_path}")"
    cp "${exe_dir}/\${file_path}" "${outputs_dir}/\${file_path}" 2>/dev/null || true
  done < "${exe_dir}/.snakemake_outputs"
  rm -f "${exe_dir}/.snakemake_outputs"
fi
SNAKEMAKE_POST_EOF
  chmod +x "${post_script}"

  generate_slurm_script "${main_cmd}" "snakemake" "bash ${post_script}"
  submit_engine_job
}

function run_ep3() {
  local container="ghcr.io/tom-tan/ep3:v1.7.0"
  main_cmd="podman run --rm --userns=keep-id -v \${_SAPPORO_PODMAN_SOCK}:/var/run/docker.sock -e DOCKER_HOST=unix:///var/run/docker.sock -v /tmp:/tmp -v ${run_dir}:${run_dir} ${extra_podman_args_str} -w ${exe_dir} ${container} ep3-runner --verbose --outdir ${outputs_dir} ${wf_engine_params} ${wf_url} ${wf_params} 1>>${stdout} 2>>${stderr}"
  generate_slurm_script "${main_cmd}" "ep3"
  submit_engine_job
}

function run_streamflow() {
  # StreamFlow's DockerConnector requires a `docker` binary. Bind-mount
  # podman as /usr/bin/docker so streamflow can invoke it transparently.
  local container="alphaunito/streamflow:0.2.0.dev14"
  main_cmd="podman run --rm --userns=keep-id -v \${_SAPPORO_PODMAN_SOCK}:/var/run/docker.sock -e DOCKER_HOST=unix:///var/run/docker.sock -v /usr/bin/podman:/usr/bin/docker:ro -v /tmp:/tmp -v ${run_dir}:${run_dir} ${extra_podman_args_str} -w ${exe_dir} ${container} cwl-runner --outdir ${outputs_dir} ${wf_engine_params} ${wf_url} ${wf_params} 1>>${stdout} 2>>${stderr}"
  generate_slurm_script "${main_cmd}" "streamflow"
  submit_engine_job
}

function cancel() {
  if [[ -f "${slurm_jobid}" ]]; then
    local job_id
    job_id=$(cat "${slurm_jobid}")
    slurm_cancel_job "${job_id}"
  fi
  cancel_by_request
}

function upload() {
  :
}

# ==============================================================
# If you are not familiar with sapporo, please don't edit below.
# ==============================================================

run_dir=$1

run_request="${run_dir}/run_request.json"
state="${run_dir}/state.txt"
exe_dir="${run_dir}/exe"
outputs_dir="${run_dir}/outputs"
# shellcheck disable=SC2034  # declared for parity with RUN_DIR_STRUCTURE
outputs="${run_dir}/outputs.json"
wf_params="${run_dir}/exe/workflow_params.json"
start_time="${run_dir}/start_time.txt"
end_time="${run_dir}/end_time.txt"
exit_code="${run_dir}/exit_code.txt"
stdout="${run_dir}/stdout.log"
stderr="${run_dir}/stderr.log"
wf_engine_params_file="${run_dir}/workflow_engine_params.txt"
cmd="${run_dir}/cmd.txt"
# shellcheck disable=SC2034  # declared for parity with RUN_DIR_STRUCTURE
system_logs="${run_dir}/system_logs.json"
ro_crate="${run_dir}/ro-crate-metadata.json"
slurm_script="${run_dir}/slurm.sh"
slurm_jobid="${run_dir}/slurm.jobid"
slurm_job_json="${run_dir}/slurm_job.json"

wf_engine=$(jq -r ".workflow_engine" "${run_request}")
wf_url=$(jq -r ".workflow_url" "${run_request}")
wf_engine_params=$(head -n 1 "${wf_engine_params_file}" 2>/dev/null || echo "")

# Shared across run_*() functions.
main_cmd=""

# SAPPORO_EXTRA_PODMAN_ARGS supersedes SAPPORO_EXTRA_DOCKER_ARGS (fallback).
extra_podman_args_str=""
if [[ -n "${SAPPORO_EXTRA_PODMAN_ARGS:-}" ]]; then
  extra_podman_args_str="${SAPPORO_EXTRA_PODMAN_ARGS}"
elif [[ -n "${SAPPORO_EXTRA_DOCKER_ARGS:-}" ]]; then
  extra_podman_args_str="${SAPPORO_EXTRA_DOCKER_ARGS}"
fi

function desc_error() {
  local original_exit_code=1
  echo "${original_exit_code}" >"${exit_code}"
  date -u +"%Y-%m-%dT%H:%M:%S" >"${end_time}"
  echo "SYSTEM_ERROR" >"${state}"
  exit "${original_exit_code}"
}

function executor_error() {
  local original_exit_code=${1:-1}
  echo "${original_exit_code}" >"${exit_code}"
  date -u +"%Y-%m-%dT%H:%M:%S" >"${end_time}"
  echo "EXECUTOR_ERROR" >"${state}"
  generate_ro_crate
  exit "${original_exit_code}"
}

function kill_by_system() {
  local signal=$1
  local original_exit_code
  case "${signal}" in
    "SIGHUP") original_exit_code=129 ;;
    "SIGINT") original_exit_code=130 ;;
    "SIGQUIT") original_exit_code=131 ;;
    "SIGTERM") original_exit_code=143 ;;
    *) original_exit_code=1 ;;
  esac
  echo "${original_exit_code}" >"${exit_code}"
  date -u +"%Y-%m-%dT%H:%M:%S" >"${end_time}"
  echo "SYSTEM_ERROR" >"${state}"
  exit "${original_exit_code}"
}

function cancel_by_request() {
  local original_exit_code=138
  echo "${original_exit_code}" >"${exit_code}"
  date -u +"%Y-%m-%dT%H:%M:%S" >"${end_time}"
  echo "CANCELED" >"${state}"
  exit "${original_exit_code}"
}

function check_canceling() {
  local state_content
  state_content=$(cat "${state}")
  if [[ "${state_content}" == "CANCELING" ]]; then
    cancel
  fi
}

trap 'desc_error' ERR
trap 'kill_by_system SIGHUP' HUP
trap 'kill_by_system SIGINT' INT
trap 'kill_by_system SIGQUIT' QUIT
trap 'kill_by_system SIGTERM' TERM
trap 'cancel' USR1

echo "QUEUED" >"${state}"

run_wf &
bg_pid=$!
wait $bg_pid || true
