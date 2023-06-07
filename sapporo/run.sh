#!/usr/bin/env bash
set -e

function run_wf() {
  echo "QUEUED" >${state}
  # e.g. when wf_engine_name=cwltool, call function run_cwltool
  local function_name="run_${wf_engine_name}"
  if [[ "$(type -t ${function_name})" == "function" ]]; then
    ${function_name}
  else
    executor_error
  fi
  clean_rundir
  exit 0
}

function run_cwltool() {
  local container="quay.io/commonwl/cwltool:3.1.20220628170238"
  local cmd_txt="${DOCKER_CMD} ${container} --outdir ${outputs_dir} ${wf_engine_params} ${wf_url} ${wf_params} 1>${stdout} 2>${stderr}"
  echo ${cmd_txt} >${cmd}
  generate_slurm_sh "${cmd_txt}"
  sbatch --parsable "${slurm_script}" >"${slurm_jobid}"
}

function run_cwltool_experimental() {
  #local container="quay.io/commonwl/cwltool:3.1.20220628170238"
  #local cmd_txt="${DOCKER_CMD} ${container} --outdir ${outputs_dir} ${wf_engine_params} ${wf_url} ${wf_params} 1>${stdout} 2>${stderr}"
  local cmd_txt="source /home/sapporo-admin/work-manabu/20221115-cwltool-imputation-server/venv-cwltool-imputation-server/bin/activate; cwltool --singularity --outdir ${outputs_dir} ${wf_url} ${wf_params} 1>${stdout} 2>${stderr}"
  echo ${cmd_txt} >${cmd}
  eval ${cmd_txt} || executor_error
  #generate_slurm_sh "${cmd_txt}"
  #sbatch --parsable "${slurm_script}" >"${slurm_jobid}"
}
function run_cwltool_experimental_slurm() {
  #local container="quay.io/commonwl/cwltool:3.1.20220628170238"
  #local cmd_txt="${DOCKER_CMD} ${container} --outdir ${outputs_dir} ${wf_engine_params} ${wf_url} ${wf_params} 1>${stdout} 2>${stderr}"
  local cmd_txt="source /home/sapporo-admin/work-manabu/20221115-cwltool-imputation-server/venv-cwltool-imputation-server/bin/activate; cwltool --singularity --outdir ${outputs_dir} ${wf_url} ${wf_params} 1>${stdout} 2>${stderr}"
  generate_slurm_sh "${cmd_txt}"
  sbatch --mem=128GB -c 16 --parsable "${slurm_script}" >"${slurm_jobid}"
}

function run_nextflow() {
  local container="nextflow/nextflow:22.04.4"
  local cmd_txt=""
  if [[ $(jq 'select(.outdir) != null' ${wf_params}) ]]; then
    # It has outdir as params.
    cmd_txt="${DOCKER_CMD} ${container} nextflow -dockerize run ${wf_url} ${wf_engine_params} -params-file ${wf_params} --outdir ${outputs_dir} 1>${stdout} 2>${stderr}"
  else
    # It has NOT outdir as params.
    cmd_txt="${DOCKER_CMD} ${container} nextflow -dockerize run ${wf_url} ${wf_engine_params} -params-file ${wf_params} -work-dir ${outputs_dir} 1>${stdout} 2>${stderr}"
  fi
  find ${exe_dir} -type f -exec chmod 777 {} \;
  echo ${cmd_txt} >${cmd}
  generate_slurm_sh "${cmd_txt}"
  sbatch --parsable "${slurm_script}" >"${slurm_jobid}"
}

function run_cromwell() {
  local container="broadinstitute/cromwell:80"
  local wf_type=$(jq -r ".workflow_type" ${run_request})
  local wf_type_version=$(jq -r ".workflow_type_version" ${run_request})
  local cmd_txt="${DOCKER_CMD} ${container} run ${wf_engine_params} ${wf_url} -i ${wf_params} -m ${exe_dir}/metadata.json --type ${wf_type} --type-version ${wf_type_version} 1>${stdout} 2>${stderr}"
  echo ${cmd_txt} >${cmd}
  local cp_outputs_cmd=""
  if [[ ${wf_type} == "CWL" ]]; then
    cp_outputs_cmd=$(
      cat <<EOF
jq -r ".outputs[].location" "${exe_dir}/metadata.json" | while read output_file; do
  cp \${output_file} ${outputs_dir}/ || true
done
EOF
    )
  elif [[ ${wf_type} == "WDL" ]]; then
    cp_outputs_cmd=$(
      cat <<EOF
jq -r ".outputs | to_entries[] | .value" "${exe_dir}/metadata.json" | while read output_file; do
  cp \${output_file} ${outputs_dir}/ || true
done
EOF
    )
  fi
  generate_slurm_sh "${cmd_txt}" "${cp_outputs_cmd}"
  sbatch --parsable "${slurm_script}" >"${slurm_jobid}"
}

function run_snakemake() {
  if [[ "${wf_url}" == http://* ]] || [[ "${wf_url}" == https://* ]]; then
    # It is a remote file.
    local wf_url_local="${exe_dir}/$(basename ${wf_url})"
    curl -fsSL -o ${wf_url_local} ${wf_url} || executor_error
  else
    # It is a local file.
    if [[ "${wf_url}" == /* ]]; then
      local wf_url_local="${wf_url}"
    else
      local wf_url_local="${exe_dir}/${wf_url}"
    fi
  fi
  local wf_basedir="$(dirname ${wf_url_local})"
  # NOTE these are common conventions but not hard requirements for Snakemake Standardized Usage.
  local wf_schemas_dir="${wf_basedir}/schemas"
  local wf_scripts_dir="${wf_basedir}/scripts"
  local wf_results_dir="${wf_basedir}/results"
  if [[ -d "${wf_scripts_dir}" ]]; then
    # directory is local (not an URL) and it exists
    chmod a+x "${wf_scripts_dir}/"*
  fi

  local container="snakemake/snakemake:v7.8.3"
  local cmd_txt="${DOCKER_CMD} ${container} snakemake ${wf_engine_params} --configfile ${wf_params} --snakefile ${wf_url_local} 1>${stdout} 2>${stderr}"
  echo ${cmd_txt} >${cmd}
  local cp_outputs_cmd=$(
    cat <<EOF
${DOCKER_CMD} ${container} snakemake --configfile ${wf_params} --snakefile ${wf_url_local} --summary 2>/dev/null | tail -n +2 | cut -f 1 |
while read file_path; do
  dir_path=\$(dirname \${file_path})
  mkdir -p "${outputs_dir}/\${dir_path}"
  cp "${exe_dir}/\${file_path}" "${outputs_dir}/\${file_path}" 2>/dev/null || true
done
EOF
  )
  generate_slurm_sh "${cmd_txt}" "${cp_outputs_cmd}"
  sbatch --parsable "${slurm_script}" >"${slurm_jobid}"
}

function generate_slurm_sh() {
  local cmd_txt=$1
  local cp_outputs_txt=${2:-}
  cat <<EOF >"${slurm_script}"
#!/bin/bash
set -eux

function executor_error() {
  # Exit case 2: The workflow_engine terminated in error.
  original_exit_code=\$?
  echo \${original_exit_code} >${exit_code}
  date +"%Y-%m-%dT%H:%M:%S" >${end_time}
  echo "EXECUTOR_ERROR" >${state}
  exit \${original_exit_code}
}

function download_workflow_attachment() {
  ~/Python-3.8.13/python -c "from sapporo.run import download_workflow_attachment; download_workflow_attachment('${run_dir}')" || executor_error
}

function generate_outputs_list() {
  ~/Python-3.8.13/python -c "from sapporo.run import dump_outputs_list; dump_outputs_list('${run_dir}')" || executor_error
}

echo "INITIALIZING" >${state}
download_workflow_attachment
echo "RUNNING" >${state}
date +"%Y-%m-%dT%H:%M:%S" >${start_time}
${cmd_txt} || executor_error
date +"%Y-%m-%dT%H:%M:%S" >${end_time}
${cp_outputs_txt}
generate_outputs_list
echo 0 >${exit_code}
echo "COMPLETE" >${state}
EOF
}

function cancel() {
  # Pre-cancellation procedures
  cancel_by_request
}

function clean_rundir() {
  # Find files under run_dir older than env integer SAPPORO_DATA_REMOVE_OLDER_THAN_DAYS and delete them in a background process
  local re_pattern="^[0-9]+$"
  local base_run_dir=$(realpath ${run_dir}/../..)
  if [[ ! -z ${SAPPORO_DATA_REMOVE_OLDER_THAN_DAYS} ]] && [[ ${SAPPORO_DATA_REMOVE_OLDER_THAN_DAYS} =~ ${re_pattern} ]]; then
    find ${base_run_dir} -mindepth 2 -maxdepth 2 -mtime "+${SAPPORO_DATA_REMOVE_OLDER_THAN_DAYS}" -type d -exec rm -r {} \; >/dev/null 2>&1 &
  fi
}

# ==============================================================
# If you are not familiar with sapporo, please don't edit below.

run_dir=$1

# Run dir structure
run_request="${run_dir}/run_request.json"
state="${run_dir}/state.txt"
exe_dir="${run_dir}/exe"
outputs_dir="${run_dir}/outputs"
outputs="${run_dir}/outputs.json"
wf_params="${run_dir}/exe/workflow_params.json"
start_time="${run_dir}/start_time.txt"
end_time="${run_dir}/end_time.txt"
exit_code="${run_dir}/exit_code.txt"
stdout="${run_dir}/stdout.log"
stderr="${run_dir}/stderr.log"
wf_engine_params_file="${run_dir}/workflow_engine_params.txt"
cmd="${run_dir}/cmd.txt"
task_logs="${run_dir}/task.log"
slurm_script="${run_dir}/slurm.sh"
slurm_jobid="${run_dir}/slurm.jobid"

# Meta characters are escaped.
wf_engine_name=$(jq -r ".workflow_engine_name" ${run_request})
wf_url=$(jq -r ".workflow_url" ${run_request})
wf_engine_params=$(head -n 1 ${wf_engine_params_file})

# Sibling docker command
D_SOCK="-v /data1/sapporo-admin/rootless_docker/run/docker.sock:/var/run/docker.sock"
D_BIN="-v /home/sapporo-admin/bin/docker:/usr/bin/docker"
D_TMP="-v /tmp:/tmp"
DOCKER_CMD="docker -H unix:///data1/sapporo-admin/rootless_docker/run/docker.sock run -i --rm ${D_SOCK} -e DOCKER_HOST=unix:///var/run/docker.sock ${D_BIN} ${D_TMP} -v ${run_dir}:${run_dir} -w=${exe_dir}"

# 4 Exit cases
# 1. The description of run.sh was wrong.
# 2. The workflow_engine terminated in error.
# 3. The system sent a signal to the run.sh, such as SIGHUP.
# 4. The request `POST /runs/${run_id}/cancel` came in.

function desc_error() {
  # Exit case 1: The description of run.sh was wrong.
  original_exit_code=$?
  echo ${original_exit_code} >${exit_code}
  date +"%Y-%m-%dT%H:%M:%S" >${end_time}
  echo "SYSTEM_ERROR" >${state}
  exit ${original_exit_code}
}

function executor_error() {
  # Exit case 2: The workflow_engine terminated in error.
  original_exit_code=$?
  echo ${original_exit_code} >${exit_code}
  date +"%Y-%m-%dT%H:%M:%S" >${end_time}
  echo "EXECUTOR_ERROR" >${state}
  exit ${original_exit_code}
}

function uploader_error() {
  # Exit case 2.1: Upload function terminated in error.
  original_exit_code=$?
  echo ${original_exit_code} >${exit_code}
  date +"%Y-%m-%dT%H:%M:%S" >${end_time}
  echo "UPLOADER_ERROR" >${state}
  exit ${original_exit_code}
}

function kill_by_system() {
  # Exit case 3: The system sent a signal to the run.sh, such as SIGHUP.
  signal=$1
  if [[ ${signal} == "SIGHUP" ]]; then
    original_exit_code=129
  elif [[ ${signal} == "SIGINT" ]]; then
    original_exit_code=130
  elif [[ ${signal} == "SIGQUIT" ]]; then
    original_exit_code=131
  elif [[ ${signal} == "SIGTERM" ]]; then
    original_exit_code=143
  fi
  echo ${original_exit_code} >${exit_code}
  date +"%Y-%m-%dT%H:%M:%S" >${end_time}
  echo "SYSTEM_ERROR" >${state}
  exit ${original_exit_code}
}

function cancel_by_request() {
  # Exit case 4: The request `POST /runs/${run_id}/cancel` came in.
  original_exit_code=138 # 138 is SIGUSR1.
  echo ${original_exit_code} >${exit_code}
  date +"%Y-%m-%dT%H:%M:%S" >${end_time}
  echo "CANCELING" >${state}
  scancel $(cat "${run_dir}/slurm.jobid")
  echo "CANCELED" >${state}
  exit ${original_exit_code}
}

trap 'desc_error' ERR              # Exit case 1
trap 'kill_by_system SIGHUP' HUP   # Exit case 3
trap 'kill_by_system SIGINT' INT   # Exit case 3
trap 'kill_by_system SIGQUIT' QUIT # Exit case 3
trap 'kill_by_system SIGTERM' TERM # Exit case 3
trap 'cancel' USR1                 # Exit case 4

run_wf
