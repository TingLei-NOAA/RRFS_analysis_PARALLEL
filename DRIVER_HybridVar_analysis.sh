#!/bin/bash
set -euo pipefail

# This script grabs the real-time background ensemble from RRFSv1 and runs a JEDI-based GETKF analysis every hour
# Tasks include:
#   1. Run bufr2ioda.x to generate IODA observations including radar obs
#   2. Set up analysis run directory using saved fix files
#   3. Run GETKF analysis

################
### Settings ###
################

# Paths to local installs
RDASApp=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-rdasapp/RDASApp
rrfsworkflow=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-fork-fv3jedi-workflow/rrfs-workflow
baserundir=/lfs/h2/emc/stmp/${USER}/3DVarAnalysis_PARALLEL

# GETKF config
getkfyaml=/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/fix/rdas-atmosphere-templates-fv3_na3km_getkf.yaml
#
HybridVaryaml=xxx/lfs/h2/emc/da/noscrub/samuel.degelia/parallel_getkf/fix/rdas-atmosphere-templates-fv3_na3km_getkf.yaml

# Paths to RRFS ensemble and observations in realtime (wont change)
rrfspath=/lfs/h1/ops/para/com/rrfs/v1.0
reflpath=/lfs/h1/ops/prod/dcom/ldmdata/obs/upperair/mrms/conus/MergedReflectivityQC
obsbase=/lfs/h1/ops/prod/com/obsproc/v1.2

#############################
### Begin executable code ###
#############################

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <enspath> <controlpath>"
    exit 1
fi

enspath="$1"
controlpath="$2"
if [[ ! -d "${enspath}" ]]; then
    echo "ERROR: enspath does not exist: ${enspath}"
    exit 1
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
source "${script_dir}/scripts/driver_analysis_common.sh"
submit="${script_dir}/scripts/submit_job.sh"

submit_job_or_exit() {
    local desc="$1"
    shift
    local jobid

    if ! jobid=$(bash "${submit}" "$@"); then
        echo "ERROR: failed to submit ${desc}" >&2
        exit 1
    fi
    if [[ -z "${jobid}" ]]; then
        echo "ERROR: ${desc} submission returned an empty job ID" >&2
        exit 1
    fi
    echo "${jobid}"
}

check_pbs_job_success() {
    local label="$1"
    local jobid="$2"
    local qstat_output
    local exit_status
    local job_state
    local comment
    local output_path
    local error_path

    qstat_output=$(qstat -x -f "${jobid}" 2>/dev/null || qstat -H -f "${jobid}" 2>/dev/null || true)
    exit_status=$(awk -F= '/Exit_status/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "${qstat_output}")
    job_state=$(awk -F= '/job_state/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' <<< "${qstat_output}")
    comment=$(awk -F= '/comment/ {sub(/^[[:space:]]*comment[[:space:]]*=[[:space:]]*/, ""); print; exit}' <<< "${qstat_output}")
    output_path=$(awk -F= '/Output_Path/ {sub(/^[[:space:]]*Output_Path[[:space:]]*=[[:space:]]*/, ""); print; exit}' <<< "${qstat_output}")
    error_path=$(awk -F= '/Error_Path/ {sub(/^[[:space:]]*Error_Path[[:space:]]*=[[:space:]]*/, ""); print; exit}' <<< "${qstat_output}")

    if [[ -z "${exit_status}" ]]; then
        echo "ERROR: Could not determine PBS Exit_status for ${label} job ${jobid}" >&2
        echo "  job_state=${job_state:-UNKNOWN}" >&2
        echo "  comment=${comment:-NONE}" >&2
        echo "  Output_Path=${output_path:-UNKNOWN}" >&2
        echo "  Error_Path=${error_path:-UNKNOWN}" >&2
        return 1
    fi

    if [[ "${exit_status}" != "0" ]]; then
        echo "ERROR: ${label} job ${jobid} failed with Exit_status=${exit_status}" >&2
        echo "  job_state=${job_state:-UNKNOWN}" >&2
        echo "  comment=${comment:-NONE}" >&2
        echo "  Output_Path=${output_path:-UNKNOWN}" >&2
        echo "  Error_Path=${error_path:-UNKNOWN}" >&2
        return 1
    fi

    echo "SUCCESS: ${label} job ${jobid} completed with Exit_status=0"
    echo "  Output_Path=${output_path:-UNKNOWN}"
    return 0
}

# -----------------------------------------------------------------------
# Per-task PBS resource settings.
# Override any of these environment variables before calling this script
# to customize queue, account, node counts, or wall-clock limits without
# editing the task scripts.
# -----------------------------------------------------------------------
PBS_ACCOUNT="RRFS-DEV"
PBS_QUEUE="dev"

# Radar reflectivity processing
RADAR_JOB_NAME="na3km_process_radarref"
RADAR_SELECT="1:mpiprocs=64:ncpus=64"
RADAR_WALLTIME="01:25:00"
RADAR_PLACE="excl"
RADAR_LOG="mrms.log"

# BUFR to IODA conversion
BUFR_JOB_NAME="na3km_ioda_bufr"
BUFR_SELECT="1:mpiprocs=1:ncpus=1:mem=20G"
BUFR_WALLTIME="01:20:00"
BUFR_PLACE="excl"
BUFR_LOG="bufr.log"

# GETKF analysis
GETKF_JOB_NAME="na3km_getkf"
GETKF_SELECT="60:mpiprocs=40:ompthreads=1:ncpus=40"
GETKF_WALLTIME="01:00:00"
GETKF_PLACE="vscatter"
GETKF_LOG="getkf.log"
# HybridVar analysis
HybridVar_JOB_NAME="na3km_hybrid"
HybridVar_SELECT="62:mpiprocs=128:ompthreads=1:ncpus=128"
HybridVar_WALLTIME="01:00:00"
HybridVar_PLACE="vscatter"
HybridVar_LOG="HybridVar.log"

# GSI verification
VERIF_JOB_NAME="na3km_verif"
VERIF_SELECT="1:ncpus=128:ompthreads=8:mem=500G"
VERIF_WALLTIME="01:00:00"
VERIF_PLACE="excl"
VERIF_LOG="verif.log"

# Get number of nodes and tasks to pass into the scripts
RADAR_PBS_NP=$(echo "${RADAR_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
RADAR_PBS_NUM_NODES=$(echo "${RADAR_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
BUFR_PBS_NP=$(echo "${BUFR_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
BUFR_PBS_NUM_NODES=$(echo "${BUFR_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
GETKF_PBS_NP=$(echo "${GETKF_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
GETKF_PBS_NUM_NODES=$(echo "${GETKF_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
HybridVar_PBS_NP=$(echo "${HybridVar_SELECT}" | grep -oP 'mpiprocs\s*=\s*\K[0-9]+')
HybridVar_PBS_NUM_NODES=$(echo "${HybridVar_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')
VERIF_PBS_NP=$(echo "${VERIF_SELECT}" | grep -oP 'ncpus\s*=\s*\K[0-9]+')
VERIF_PBS_NUM_NODES=$(echo "${VERIF_SELECT}" | grep -oP '^\s*\K[0-9]+(?=\s*:)')

# NOTE: the enspath contains RESTART files for the next forecast hour
# So enkfrrfs.20260416/15 contains the restart files for 2026041616
# Thus we need to look for obs at one hour after the restart file
HH=${enspath##*/}
if ! compute_valid_cycle_from_enspath "${enspath}"; then
    echo "ERROR: invalid cycle time parsed from enspath: ${enspath}"
    exit 1
fi
YYYYMMDD=${VALID_YYYYMMDD}
HH=${VALID_HH}
YYYY=${VALID_YYYY}
MM=${VALID_MM}
DD=${VALID_DD}
obspath=${obsbase}/rrfs.${YYYYMMDD}
bufrdir=${baserundir}/bufr.${YYYYMMDD}${HH}
mrmsdir=${baserundir}/mrms.${YYYYMMDD}${HH}
anldir=${baserundir}/HybridVar.${YYYYMMDD}${HH}
verifdir=${baserundir}/HybridVar_verif.${YYYYMMDD}${HH}
cycle_logdir=${anldir}/logs
currdir=`pwd`
echo "DRIVER_HybridVar_analysis.sh working directory: ${currdir}"
fixsimple=${currdir}/fix
if [ ! -d ./logs ]; then
  mkdir -p logs
fi
echo "DRIVER_HybridVar_analysis.sh repository log directory: ${currdir}/logs"

# Export the variables we will need in other tasks
envfile=HybridVar_run.env
envfile_abs=${currdir}/${envfile}
cat > "${envfile_abs}" << EOF
RDASApp='${RDASApp}'
rrfsworkflow='${rrfsworkflow}'
rrfspath='${rrfspath}'
reflpath='${reflpath}'
obsbase='${obsbase}'
obspath='${obspath}'
baserundir='${baserundir}'
enspath='${enspath}'
controlpath='${controlpath}'
HH='${HH}'
YYYYMMDD='${YYYYMMDD}'
YYYY='${YYYY}'
MM='${MM}'
DD='${DD}'
bufrdir='${bufrdir}'
mrmsdir='${mrmsdir}'
anldir='${anldir}'
verifdir='${verifdir}'
cycle_logdir='${cycle_logdir}'
HybridVaryaml='${HybridVaryaml}'
fixsimple='${fixsimple}'
EOF

if [ -d ${bufrdir} ]; then
  rm -rf ${bufrdir}
fi
if [ -d ${mrmsdir} ]; then
  rm -rf ${mrmsdir}
fi
if [ -d ${anldir} ]; then
  rm -rf ${anldir}
fi
if [ -d ${verifdir} ]; then
  rm -rf ${verifdir}
fi
mkdir -p ${bufrdir}
mkdir -p ${mrmsdir}
mkdir -p ${anldir}
mkdir -p ${verifdir}
mkdir -p ${cycle_logdir}
RADAR_LOG="${cycle_logdir}/mrms.log"
BUFR_LOG="${cycle_logdir}/bufr.log"
HybridVar_LOG="${cycle_logdir}/HybridVar.log"
VERIF_LOG="${cycle_logdir}/verif.log"
job_envfile="${cycle_logdir}/${envfile}"
rm -f "${RADAR_LOG}" "${BUFR_LOG}" "${HybridVar_LOG}" "${VERIF_LOG}"
cp "${envfile_abs}" "${job_envfile}"
cp "${job_envfile}" ${bufrdir}
cp "${job_envfile}" ${mrmsdir}
cp "${job_envfile}" ${anldir}
cp "${job_envfile}" ${verifdir}
cp ./scripts/prep_ioda_cast.sh ${bufrdir}
cp ./scripts/prep_phydata_dbz.py ${anldir}
cp ./scripts/apply_jedi_incs.sh ${verifdir}

echo "HybridVar cycle run directories:"
echo "  BUFR work directory: ${bufrdir}"
echo "  MRMS work directory: ${mrmsdir}"
echo "  HybridVar analysis directory: ${anldir}"
echo "  Verification work directory: ${verifdir}"
echo "HybridVar cycle log directory: ${cycle_logdir}"
echo "HybridVar environment file used by PBS jobs: ${job_envfile}"
echo "  radar PBS log: ${RADAR_LOG}"
echo "  bufr PBS log: ${BUFR_LOG}"
echo "  HybridVar PBS log: ${HybridVar_LOG}"
echo "  verif PBS log: ${VERIF_LOG}"
echo "  HybridVar internal pgmout: ${anldir}/pgm.log"
debug_hybridvar_script="${cycle_logdir}/sub_hybridvar.sh"
debug_verification_script="${cycle_logdir}/sub_verification.sh"

# Create radar observations
echo "Submitting radar task: ${script_dir}/scripts/exrrfs_process_radar.sh"
echo "  PBS stdout/stderr: ${RADAR_LOG}"
job1=$(submit_job_or_exit "radar processing job" \
    -N "${RADAR_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${RADAR_SELECT}" \
    -l "walltime=${RADAR_WALLTIME}" \
    -l "place=${RADAR_PLACE}" \
    -o "${RADAR_LOG}" \
    -v "envfile=${job_envfile}" \
    -v "PBS_NP=${RADAR_PBS_NP},PBS_NUM_NODES=${RADAR_PBS_NUM_NODES}" \
    "${script_dir}/scripts/exrrfs_process_radar.sh")

# Convert prepbufr observations to IODA
echo "Submitting BUFR/IODA task: ${script_dir}/scripts/exrrfs_ioda_bufr.sh"
echo "  PBS stdout/stderr: ${BUFR_LOG}"
job2=$(submit_job_or_exit "BUFR to IODA job" \
    -N "${BUFR_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${BUFR_SELECT}" \
    -l "walltime=${BUFR_WALLTIME}" \
    -l "place=${BUFR_PLACE}" \
    -o "${BUFR_LOG}" \
    -v "envfile=${job_envfile}" \
    -v "PBS_NP=${BUFR_PBS_NP},PBS_NUM_NODES=${BUFR_PBS_NUM_NODES}" \
    "${script_dir}/scripts/exrrfs_ioda_bufr.sh")

# Run the GETKF analysis after both upstream jobs complete successfully
#    -W "depend=afterok:${job1}:${job2}" \
#    
cat > "${debug_hybridvar_script}" << EOF
#!/bin/bash
# Debug resubmission script generated by DRIVER_HybridVar_analysis.sh.
# It can be rerun directly with:
#   qsub ${debug_hybridvar_script}
#
# Original dependency from the automated workflow:
#   afterok:${job1}:${job2}

#PBS -A ${PBS_ACCOUNT}
#PBS -q ${PBS_QUEUE}
#PBS -l select=${HybridVar_SELECT}
#PBS -l walltime=${HybridVar_WALLTIME}
#PBS -N ${HybridVar_JOB_NAME}
#PBS -j oe -o ${HybridVar_LOG}
#PBS -l place=${HybridVar_PLACE}

export envfile="${job_envfile}"
export PBS_NP="${HybridVar_PBS_NP}"
export PBS_NUM_NODES="${HybridVar_PBS_NUM_NODES}"

echo "Debug HybridVar job starting"
echo "  submit directory before cd: \$(pwd)"
echo "  envfile=\${envfile}"
echo "  PBS_NP=\${PBS_NP}"
echo "  PBS_NUM_NODES=\${PBS_NUM_NODES}"
source "\${envfile}"
echo "  anldir=\${anldir}"
echo "  HybridVaryaml=\${HybridVaryaml}"

cd "${currdir}"
exec bash "${script_dir}/scripts/exrrfs_analysis_HybridVar_jedi.sh"
EOF
chmod +x "${debug_hybridvar_script}"
cp "${debug_hybridvar_script}" "${currdir}/sub_hybridvar.sh"
echo "Wrote debug HybridVar PBS script: ${debug_hybridvar_script}"
echo "Convenience copy: ${currdir}/sub_hybridvar.sh"

echo "Submitting HybridVar analysis task: ${script_dir}/scripts/exrrfs_analysis_HybridVar_jedi.sh"
echo "  PBS stdout/stderr: ${HybridVar_LOG}"
echo "  Task work directory after cd: ${anldir}"
echo "  Task internal pgmout: ${anldir}/pgm.log"
echo "  Dependency: afterok:${job1}:${job2}"
job3=$(submit_job_or_exit "HybridVar analysis job" \
    -N "${HybridVar_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${HybridVar_SELECT}" \
    -l "walltime=${HybridVar_WALLTIME}" \
    -l "place=${HybridVar_PLACE}" \
    -o "${HybridVar_LOG}" \
    -v "envfile=${job_envfile}" \
    -v "PBS_NP=${HybridVar_PBS_NP},PBS_NUM_NODES=${HybridVar_PBS_NUM_NODES}" \
    -W "depend=afterok:${job1}:${job2}" \
    "${script_dir}/scripts/exrrfs_analysis_HybridVar_jedi.sh")
echo "Submitted HybridVar analysis job: ${job3}"
echo "HybridVar PBS log will appear after the job starts: ${HybridVar_LOG}"

cat > "${debug_verification_script}" << EOF
#!/bin/bash
# Debug resubmission script generated by DRIVER_HybridVar_analysis.sh.
# It can be rerun directly with:
#   qsub ${debug_verification_script}
#
# Original dependency from the automated workflow:
#   afterok:${job3}

#PBS -A ${PBS_ACCOUNT}
#PBS -q ${PBS_QUEUE}
#PBS -l select=${VERIF_SELECT}
#PBS -l walltime=${VERIF_WALLTIME}
#PBS -N ${VERIF_JOB_NAME}
#PBS -j oe -o ${VERIF_LOG}
#PBS -l place=${VERIF_PLACE}

export envfile="${job_envfile}"
export PBS_NP="${VERIF_PBS_NP}"
export PBS_NUM_NODES="${VERIF_PBS_NUM_NODES}"

echo "Debug verification job starting"
echo "  submit directory before cd: \$(pwd)"
echo "  envfile=\${envfile}"
echo "  PBS_NP=\${PBS_NP}"
echo "  PBS_NUM_NODES=\${PBS_NUM_NODES}"
source "\${envfile}"
echo "  verifdir=\${verifdir}"
echo "  anldir=\${anldir}"

cd "${currdir}"
exec bash "${script_dir}/scripts/exrrfs_analysis_gsi.sh"
EOF
chmod +x "${debug_verification_script}"
cp "${debug_verification_script}" "${currdir}/sub_verification.sh"
echo "Wrote debug verification PBS script: ${debug_verification_script}"
echo "Convenience copy: ${currdir}/sub_verification.sh"

# Run the verification after the GETKF job completes successfully
echo "Submitting GSI verification task: ${script_dir}/scripts/exrrfs_analysis_gsi.sh"
echo "  PBS stdout/stderr: ${VERIF_LOG}"
echo "  Dependency: afterok:${job3}"
job4=$(submit_job_or_exit "GSI verification job" \
    -N "${VERIF_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${VERIF_SELECT}" \
    -l "walltime=${VERIF_WALLTIME}" \
    -l "place=${VERIF_PLACE}" \
    -o "${VERIF_LOG}" \
    -v "envfile=${job_envfile}" \
    -v "PBS_NP=${VERIF_PBS_NP},PBS_NUM_NODES=${VERIF_PBS_NUM_NODES}" \
    -W "depend=afterok:${job3}" \
    "${script_dir}/scripts/exrrfs_compare_HybridVar_jedi_gsi.sh")
echo "Submitted GSI verification job: ${job4}"
echo "GSI verification PBS log will appear after the job starts: ${VERIF_LOG}"

#cltorg echo "Submitted jobs: radar=${job1} bufr=${job2} getkf=${job3} verif=${job4}"
echo "Submitted jobs: radar=${job1} bufr=${job2} HybridVar=${job3} verif=${job4}"

# Wait for all jobs to complete
xtrace_was_on=0
case "$-" in
  *x*)
    xtrace_was_on=1
    set +x
    ;;
esac
while qstat_output=$(qstat "${job1}" "${job2}" "${job3}" "${job4}" 2>/dev/null || true); do
    if [[ "${qstat_output}" != *"${job1}"* && \
          "${qstat_output}" != *"${job2}"* && \
          "${qstat_output}" != *"${job3}"* && \
          "${qstat_output}" != *"${job4}"* ]]; then
        break
    fi
    sleep 10
done
if [[ "${xtrace_was_on}" -eq 1 ]]; then
    set -x
fi

check_pbs_job_success "radar" "${job1}"
check_pbs_job_success "bufr" "${job2}"
check_pbs_job_success "HybridVar" "${job3}"
check_pbs_job_success "verif" "${job4}"

echo "HybridVar driver finished waiting for submitted jobs."
echo "Cycle logs are in: ${cycle_logdir}"
echo "  radar PBS log: ${RADAR_LOG}"
echo "  bufr PBS log: ${BUFR_LOG}"
echo "  HybridVar PBS log: ${HybridVar_LOG}"
echo "  verif PBS log: ${VERIF_LOG}"
echo "  HybridVar internal pgmout: ${anldir}/pgm.log"
echo "  debug resubmission script: ${debug_hybridvar_script}"
echo "  debug verification script: ${debug_verification_script}"
echo "  saved environment file: ${job_envfile}"

exit 0
