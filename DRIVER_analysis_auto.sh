#!/bin/bash

rrfspath=${RRFSPATH:-/lfs/h1/ops/para/com/rrfs/v1.0}
baserundir=${BASERUNDIR:-/lfs/h2/emc/stmp/${USER}/GETKF_PARALLEL}
HybridVar_baserundir=${HybridVar_BASERUNDIR:-/lfs/h2/emc/stmp/${USER}/HybridVar_PARALLEL}
lockfile=${LOCKFILE:-${baserundir}/.enspath_lock}
cycle_history=${baserundir}/.enspath_cycle_history.txt
HybridVar_cycle_history=${HybridVar_baserundir}/.enspath_cycle_history.txt
timestamp=$(date -u +%Y%m%d%H%M%S)
status_file=${HybridVar_baserundir}/monitor_enspath_${timestamp}.status
script_dir=$(cd "$(dirname "$0")" && pwd)
driver_script=${DRIVER_SCRIPT:-${script_dir}/DRIVER_analysis.sh}
driver_HybridVar_script=${DRIVER_SCRIPT:-${script_dir}/DRIVER_HybridVar_analysis.sh}
lock_acquired=0
ensemble_size=${ENSEMBLE_SIZE:-30}

source "${script_dir}/scripts/driver_analysis_common.sh"

if ! mkdir -p "${baserundir}"; then
    echo "ERROR: Unable to create baserundir: ${baserundir}" >&2
    exit 1
fi
if ! mkdir -p "${HybridVar_baserundir}"; then
    echo "ERROR: Unable to create baserundir: ${HybridVar_baserundir}" >&2
    exit 1
fi
if ! touch "${cycle_history}"; then
    echo "ERROR: Unable to initialize cycle history file: ${cycle_history}" >&2
    exit 1
fi
if ! touch "${HybridVar_cycle_history}"; then
    echo "ERROR: Unable to initialize cycle history file: ${HybridVar_cycle_history}" >&2
    exit 1
fi
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
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "${status_file}"
}

release_lock() {
    if [[ "${lock_acquired}" -eq 1 && -f "${lockfile}" ]]; then
        lock_pid=$(awk -F= '/^pid=/{print $2}' "${lockfile}" 2>/dev/null)
        if [[ "${lock_pid}" == "$$" ]]; then
            rm -f "${lockfile}"
        fi
    fi
}
trap release_lock EXIT INT TERM

lock_is_active() {
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
    awk 'BEGIN{last=""} $2=="SUCCESS"{last=$1} END{if(last!="") print last; else exit 1}' "${cycle_history}"
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
    local last_processed_cycle
    local next_cycle
    local cycle

    if ! last_processed_cycle=$(get_last_processed_cycle); then
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
    local member
    local restart_dir
    local suffix
    local file
    local missing=0

    if ! compute_valid_cycle_from_enspath "${enspath}"; then
        log "ERROR: invalid cycle parsed from enspath: ${enspath}"
        return 1
    fi
    restart_prefix="${VALID_RESTART_PREFIX}"
    log "Validating member restart files for ${enspath} (prefix ${restart_prefix})"

    for member_num in $(seq 1 "${ensemble_size}"); do
        member=$(printf "m%03d" "${member_num}")
        restart_dir="${enspath}/${member}/forecast/RESTART"
        if [[ ! -d "${restart_dir}" ]]; then
            log "MISSING: ${restart_dir}"
            missing=1
            continue
        fi
        for suffix in "${required_suffixes[@]}"; do
            file="${restart_dir}/${restart_prefix}.${suffix}"
            if [[ ! -f "${file}" ]]; then
                log "MISSING: ${file}"
                missing=1
            fi
        done
    done

    if [[ "${missing}" -ne 0 ]]; then
        return 1
    fi
    return 0
}

acquire_lock() {
    local cycle="$1"
    if [[ -f "${lockfile}" ]]; then
        if lock_is_active; then
            log "Lock exists (${lockfile}); a run is already in progress."
            return 1
        fi
        log "Removing stale lock file: ${lockfile}"
        rm -f "${lockfile}"
    fi
    cat > "${lockfile}" << EOF
pid=$$
cycle=${cycle}
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
owner=automated_driver
EOF
    lock_acquired=1
    return 0
}

record_processed_cycle() {
    local cycle="$1"
    local status="$2"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "${cycle} ${status} ${ts}" >> "${cycle_history}"
}

if [[ ! -x "${driver_script}" ]]; then
    log "ERROR: DRIVER script not found or not executable: ${driver_script}"
    exit 1
fi

next_cycle=$(get_next_cycle_to_process)
if [[ -z "${next_cycle}" ]]; then
    log "No new cycles with complete restart files found."
    exit 0
fi
next_enspath="${rrfspath}/enkfrrfs.${next_cycle:0:8}/${next_cycle:8:2}"
log "Found next cycle to process: ${next_cycle} (${next_enspath})"

if ! validate_restart_files "${next_enspath}"; then
    log "Not all required files are available yet for cycle ${next_cycle}. Will retry on next cron run."
    exit 0
fi
log "All required files are present for cycle ${next_cycle}"

if ! acquire_lock "${next_cycle}"; then
    exit 0
fi

log "Starting DRIVER_analysis.sh for cycle ${next_cycle}"
if "${driver_script}" "${next_enspath}" >> "${status_file}" 2>&1; then
    log "DRIVER completed successfully for cycle ${next_cycle}"
    record_processed_cycle "${next_cycle}" "SUCCESS"
else
    log "DRIVER failed for cycle ${next_cycle}; leaving cycle unprocessed for retry."
    record_processed_cycle "${next_cycle}" "FAILED"
    exit 1
fi
