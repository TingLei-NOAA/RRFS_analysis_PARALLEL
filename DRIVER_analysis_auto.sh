#!/bin/bash
#
# Automated RRFS analysis launcher for regular Rocoto/cron-style polling.
#
# Each invocation checks the upstream RRFS ensemble restart tree for the next
# complete cycle and launches one analysis branch. Branch selection is controlled
# by RUN_BRANCH, with default RUN_BRANCH=HybridVar. Valid values are GETKF,
# HybridVar, or both. RUN_BRNACH is also accepted as a spelling alias.
# Set FORCE_CLEAN_LOCKS=TRUE to remove the selected branch lock file(s) and exit
# without launching any branch.
#
# GETKF and HybridVar are managed independently. Each branch has its own base
# run directory, cycle history file, lock file, monitor log, and driver script.
# A SUCCESS entry in that branch's history advances it to the next hourly cycle.
# A FAILED entry does not count as processed, so the same cycle is retried on
# the next invocation.
#
# The per-invocation monitor log is written as:
#
#   ${branch_baserundir}/monitor_enspath_${timestamp}.status
#
# The monitor log records this wrapper's decisions and receives stdout/stderr
# from the branch driver script.
#
# To force a branch to begin at a target cycle, write the previous cycle as a
# SUCCESS entry in that branch's history file. Example for HybridVar beginning
# at 2024052700:
#
#   echo "2024052623 SUCCESS manual_start" > /lfs/h2/emc/stmp/${USER}/HybridVar_PARALLEL/.enspath_cycle_history.txt
#
# To remove lock files without launching new work:
#
#   FORCE_CLEAN_LOCKS=TRUE RUN_BRANCH=HybridVar ./DRIVER_analysis_auto.sh
#   FORCE_CLEAN_LOCKS=TRUE RUN_BRANCH=GETKF ./DRIVER_analysis_auto.sh
#   FORCE_CLEAN_LOCKS=TRUE RUN_BRANCH=both ./DRIVER_analysis_auto.sh

set -euo pipefail
if [[ "${TRACE_AUTO:-FALSE}" == "TRUE" ]]; then
    PS4='+ ${BASH_SOURCE}:${LINENO}: '
    set -x
fi
rrfspath=${RRFSPATH:-/lfs/h1/ops/para/com/rrfs/v1.0}
baserundir=${BASERUNDIR:-/lfs/h2/emc/stmp/${USER}/GETKF_PARALLEL}
HybridVar_baserundir=${HybridVar_BASERUNDIR:-/lfs/h2/emc/stmp/${USER}/HybridVar_PARALLEL}
lockfile=${LOCKFILE:-${baserundir}/.enspath_lock}
HybridVar_lockfile=${HybridVar_LOCKFILE:-${HybridVar_baserundir}/.enspath_lock}
cycle_history=${baserundir}/.enspath_cycle_history.txt
HybridVar_cycle_history=${HybridVar_baserundir}/.enspath_cycle_history.txt
timestamp=$(date -u +%Y%m%d%H%M%S)
status_file=${baserundir}/monitor_enspath_${timestamp}.status
HybridVar_status_file=${HybridVar_baserundir}/monitor_enspath_${timestamp}.status
script_dir=$(cd "$(dirname "$0")" && pwd)
driver_script=${DRIVER_SCRIPT:-${script_dir}/DRIVER_analysis.sh}
driver_HybridVar_script=${DRIVER_HYBRIDVAR_SCRIPT:-${script_dir}/DRIVER_HybridVar_analysis.sh}
lockfiles_acquired=()
ensemble_size=${ENSEMBLE_SIZE:-30}
run_branch_selection=${RUN_BRANCH:-${RUN_BRNACH:-HybridVar}}
echo RUN_BRANCH_SELECTION is $run_branch_selection

source "${script_dir}/scripts/driver_analysis_common.sh"

if ! [[ "${ensemble_size}" =~ ^[0-9]+$ ]] || [[ "${ensemble_size}" -lt 1 ]]; then
    echo "ERROR: ENSEMBLE_SIZE must be a positive integer: ${ensemble_size}" >&2
    exit 1
fi

required_suffixes=(
    "coupler.res"
    "fv_core.res.nc"
    "fv_core.res.tile1.nc"
    "fv_diag.res.tile1.nc"
    "fv_srf_wnd.res.tile1.nc"
    "fv_tracer.res.tile1.nc"
    "phy_data.nc"
    "sfc_data.nc"
)

log() {
    local status_file="$1"
    local branch_name="$2"
    shift 2
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [${branch_name}] $*" | tee -a "${status_file}"
}

release_lock() {
    local lockfile="$1"
    local lock_pid

    if [[ -f "${lockfile}" ]]; then
        lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockfile}" 2>/dev/null)
        if [[ "${lock_pid}" == "$$" ]]; then
            rm -f "${lockfile}"
        fi
    fi
}

cleanup_locks() {
    local acquired_lockfile

    for acquired_lockfile in "${lockfiles_acquired[@]}"; do
        release_lock "${acquired_lockfile}"
    done
}
trap cleanup_locks EXIT INT TERM

force_clean_lock() {
    local branch_name="$1"
    local lockfile="$2"

    if [[ -f "${lockfile}" ]]; then
        echo "[${branch_name}] Removing lock file: ${lockfile}"
        cat "${lockfile}"
        rm -f "${lockfile}"
    else
        echo "[${branch_name}] No lock file found: ${lockfile}"
    fi
}

force_clean_selected_locks() {
    case "${run_branch_selection}" in
        GETKF|getkf|ENKF|enkf)
            force_clean_lock "GETKF" "${lockfile}"
            ;;
        HybridVar|hybridvar|HYBRIDVAR|hybrid|HYBRID)
            force_clean_lock "HybridVar" "${HybridVar_lockfile}"
            ;;
        both|BOTH|all|ALL)
            force_clean_lock "GETKF" "${lockfile}"
            force_clean_lock "HybridVar" "${HybridVar_lockfile}"
            ;;
        *)
            echo "ERROR: RUN_BRANCH must be one of: GETKF, HybridVar, both" >&2
            exit 1
            ;;
    esac
}

lock_is_active() {
    local lockfile="$1"
    local lock_pid

    lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockfile}" 2>/dev/null)
    [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null
}

parse_cycle_from_path() {
    local path="$1"
    if [[ "${path}" =~ enkfrrfs\.([0-9]{8})/([0-9]{2})$ ]]; then
        echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

get_last_processed_cycle() {
    local history_file="$1"
    awk 'BEGIN{last=""} $2=="SUCCESS"{last=$1} END{if(last!="") print last; else exit 1}' "${history_file}"
}

increment_cycle() {
    local cycle="$1"
    local cycle_epoch
    local timestamp
    if ! [[ "${cycle}" =~ ^[0-9]{10}$ ]]; then
        echo "ERROR: invalid cycle format for increment: ${cycle}" >&2
        return 1
    fi
    cycle_epoch=$(date -u -d "${cycle:0:4}-${cycle:4:2}-${cycle:6:2} ${cycle:8:2}:00:00" +%s) || return 1
    timestamp=$(date -u -d "@$((cycle_epoch + 3600))" +%Y%m%d%H) || {
        echo "ERROR: unable to increment cycle: ${cycle}" >&2
        return 1
    }
    echo "${timestamp}"
}

cycle_exists_and_has_restarts() {
    local cycle="$1"
    local enspath="${rrfspath}/enkfrrfs.${cycle:0:8}/${cycle:8:2}"
    [[ -d "${enspath}" ]] || return 1
    validate_restart_files "${enspath}" >/dev/null
}

get_next_cycle_to_process() {
    local history_file="$1"
    local last_processed_cycle
    local next_cycle
    local cycle

    if ! last_processed_cycle=$(get_last_processed_cycle "${history_file}"); then
        while read -r path; do
            if cycle=$(parse_cycle_from_path "${path}") && cycle_exists_and_has_restarts "${cycle}"; then
                echo "${cycle}"
                return 0
            fi
        # Reverse sort ensures the first valid match is the latest complete cycle.
        done < <(find "${rrfspath}" -mindepth 2 -maxdepth 2 -type d -regextype posix-extended \
            -regex ".*/enkfrrfs\.[0-9]{8}/[0-9]{2}" | sort -r)
        return 1
    fi

    next_cycle=$(increment_cycle "${last_processed_cycle}") || return 1
    if cycle_exists_and_has_restarts "${next_cycle}"; then
        echo "${next_cycle}"
        return 0
    fi
    return 1
}

validate_restart_files() {
    local enspath="$1"
    local status_file="${2:-/dev/null}"
    local branch_name="${3:-VALIDATE}"
    local member
    local restart_dir
    local suffix
    local file
    local missing=0

    if ! compute_valid_cycle_from_enspath "${enspath}"; then
        log "${status_file}" "${branch_name}" "ERROR: invalid cycle parsed from enspath: ${enspath}"
        return 1
    fi
    restart_prefix="${VALID_RESTART_PREFIX}"
    log "${status_file}" "${branch_name}" "Validating member restart files for ${enspath} (prefix ${restart_prefix})"

    for member_num in $(seq 1 "${ensemble_size}"); do
        member=$(printf "m%03d" "${member_num}")
        restart_dir="${enspath}/${member}/forecast/RESTART"
        if [[ ! -d "${restart_dir}" ]]; then
            log "${status_file}" "${branch_name}" "MISSING: ${restart_dir}"
            missing=1
            continue
        fi
        for suffix in "${required_suffixes[@]}"; do
            file="${restart_dir}/${restart_prefix}.${suffix}"
            if [[ ! -f "${file}" ]]; then
                log "${status_file}" "${branch_name}" "MISSING: ${file}"
                missing=1
            fi
        done
    done

    if [[ "${missing}" -ne 0 ]]; then
        return 1
    fi
    return 0
}

validate_control_restart_files() {
    local controlpath="$1"
    local status_file="${2:-/dev/null}"
    local branch_name="${3:-VALIDATE}"
    local restart_dir
    local suffix
    local file
    local missing=0

    if ! compute_valid_cycle_from_enspath "${controlpath}"; then
        log "${status_file}" "${branch_name}" "ERROR: invalid cycle parsed from control path: ${controlpath}"
        return 1
    fi

    restart_prefix="${VALID_RESTART_PREFIX}"
    restart_dir="${controlpath}/forecast/RESTART"
    log "${status_file}" "${branch_name}" "Validating control restart files for ${controlpath} (prefix ${restart_prefix})"

    if [[ ! -d "${restart_dir}" ]]; then
        log "${status_file}" "${branch_name}" "MISSING: ${restart_dir}"
        return 1
    fi

    for suffix in "${required_suffixes[@]}"; do
        file="${restart_dir}/${restart_prefix}.${suffix}"
        if [[ ! -f "${file}" ]]; then
            log "${status_file}" "${branch_name}" "MISSING: ${file}"
            missing=1
        fi
    done

    if [[ "${missing}" -ne 0 ]]; then
        return 1
    fi
    return 0
}

acquire_lock() {
    local lockfile="$1"
    local cycle="$2"
    local status_file="$3"
    local branch_name="$4"

    if [[ -f "${lockfile}" ]]; then
        if lock_is_active "${lockfile}"; then
            log "${status_file}" "${branch_name}" "Lock exists (${lockfile}); a run is already in progress."
            return 1
        fi
        log "${status_file}" "${branch_name}" "Removing stale lock file: ${lockfile}"
        rm -f "${lockfile}"
    fi
    cat > "${lockfile}" << EOF
pid=$$
cycle=${cycle}
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
owner=automated_driver_${branch_name}
EOF
    lockfiles_acquired+=("${lockfile}")
    return 0
}

record_processed_cycle() {
    local history_file="$1"
    local cycle="$2"
    local status="$3"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "${cycle} ${status} ${ts}" >> "${history_file}"
}

initialize_branch() {
    local branch_name="$1"
    local branch_baserundir="$2"
    local branch_cycle_history="$3"

    if ! mkdir -p "${branch_baserundir}"; then
        echo "ERROR: Unable to create ${branch_name} baserundir: ${branch_baserundir}" >&2
        return 1
    fi
    if ! touch "${branch_cycle_history}"; then
        echo "ERROR: Unable to initialize ${branch_name} cycle history file: ${branch_cycle_history}" >&2
        return 1
    fi
}

run_branch() {
    local branch_name="$1"
    local branch_baserundir="$2"
    local branch_cycle_history="$3"
    local branch_lockfile="$4"
    local branch_status_file="$5"
    local branch_driver_script="$6"
    local next_cycle
    local next_enspath
    local next_controlpath
    local controlpath
    local -a driver_cmd

    if ! initialize_branch "${branch_name}" "${branch_baserundir}" "${branch_cycle_history}"; then
        return 1
    fi
    log "${branch_status_file}" "${branch_name}" "Monitor log for this invocation: ${branch_status_file}"
    log "${branch_status_file}" "${branch_name}" "Auto wrapper working directory: $(pwd)"

    if [[ ! -x "${branch_driver_script}" ]]; then
        log "${branch_status_file}" "${branch_name}" "ERROR: DRIVER script not found or not executable: ${branch_driver_script}; see monitor log ${branch_status_file}"
        return 1
    fi

    next_cycle=$(get_next_cycle_to_process "${branch_cycle_history}")
    if [[ -z "${next_cycle}" ]]; then
        log "${branch_status_file}" "${branch_name}" "No new cycles with complete restart files found."
        return 0
    fi

    next_enspath="${rrfspath}/enkfrrfs.${next_cycle:0:8}/${next_cycle:8:2}"
    log "${branch_status_file}" "${branch_name}" "Found next cycle to process: ${next_cycle} (${next_enspath})"

    if ! validate_restart_files "${next_enspath}" "${branch_status_file}" "${branch_name}"; then
        log "${branch_status_file}" "${branch_name}" "Not all required files are available yet for cycle ${next_cycle}. Will retry on next run."
        return 0
    fi
    log "${branch_status_file}" "${branch_name}" "All required files are present for cycle ${next_cycle}"

    if [[ "${branch_name}" == "HybridVar" ]]; then
        next_controlpath="${rrfspath}/rrfs.${next_cycle:0:8}/${next_cycle:8:2}"
        if ! validate_control_restart_files "${next_controlpath}" "${branch_status_file}" "${branch_name}"; then
            log "${branch_status_file}" "${branch_name}" "Control forecast restart files are not complete yet for cycle ${next_cycle}. Will retry on next run."
            return 0
        fi
        log "${branch_status_file}" "${branch_name}" "All required control forecast files are present for cycle ${next_cycle}"
    fi

    if ! acquire_lock "${branch_lockfile}" "${next_cycle}" "${branch_status_file}" "${branch_name}"; then
        return 0
    fi

    log "${branch_status_file}" "${branch_name}" "Starting ${branch_driver_script} for cycle ${next_cycle}; driver output will be appended to ${branch_status_file}"
    if [[ "${TRACE_DRIVER:-FALSE}" == "TRUE" ]]; then
        driver_cmd=(bash -x "${branch_driver_script}" "${next_enspath}" "${next_controlpath}")
    else
        driver_cmd=(bash "${branch_driver_script}" "${next_enspath}"  "${next_controlpath:-XXXX_not_used}")
    fi

    if "${driver_cmd[@]}" >> "${branch_status_file}" 2>&1; then
        log "${branch_status_file}" "${branch_name}" "DRIVER completed successfully for cycle ${next_cycle}; see monitor log ${branch_status_file}"
        record_processed_cycle "${branch_cycle_history}" "${next_cycle}" "SUCCESS"
        release_lock "${branch_lockfile}"
        return 0
    fi

    log "${branch_status_file}" "${branch_name}" "DRIVER failed for cycle ${next_cycle}; leaving cycle unprocessed for retry. Driver output is in ${branch_status_file}"
    record_processed_cycle "${branch_cycle_history}" "${next_cycle}" "FAILED"
    release_lock "${branch_lockfile}"
    return 1
}

rc=0
if [[ "${FORCE_CLEAN_LOCKS:-FALSE}" == "TRUE" ]]; then
    force_clean_selected_locks
    exit 0
fi

case "${run_branch_selection}" in
    GETKF|getkf|ENKF|enkf)
        run_branch "GETKF" "${baserundir}" "${cycle_history}" "${lockfile}" "${status_file}" "${driver_script}" || rc=1
        ;;
    HybridVar|hybridvar|HYBRIDVAR|hybrid|HYBRID)
        run_branch "HybridVar" "${HybridVar_baserundir}" "${HybridVar_cycle_history}" "${HybridVar_lockfile}" "${HybridVar_status_file}" "${driver_HybridVar_script}" || rc=1
        ;;
    both|BOTH|all|ALL)
        run_branch "GETKF" "${baserundir}" "${cycle_history}" "${lockfile}" "${status_file}" "${driver_script}" || rc=1
        run_branch "HybridVar" "${HybridVar_baserundir}" "${HybridVar_cycle_history}" "${HybridVar_lockfile}" "${HybridVar_status_file}" "${driver_HybridVar_script}" || rc=1
        ;;
    *)
        echo "ERROR: RUN_BRANCH must be one of: GETKF, HybridVar, both" >&2
        exit 1
        ;;
esac
exit "${rc}"
