#!/bin/bash

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

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <enspath>"
    exit 1
fi
enspath="$1"
if [[ ! -d "${enspath}" ]]; then
    echo "ERROR: enspath does not exist: ${enspath}"
    exit 1
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
source "${script_dir}/scripts/driver_analysis_common.sh"
submit="${script_dir}/scripts/submit_job.sh"

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
RADAR_WALLTIME="00:25:00"
RADAR_PALCE="excl"
RADAR_LOG="mrms.log"

# BUFR to IODA conversion
BUFR_JOB_NAME="na3km_ioda_bufr"
BUFR_SELECT="1:mpiprocs=1:ncpus=1:mem=20G"
BUFR_WALLTIME="00:20:00"
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
currdir=`pwd`
fixsimple=${currdir}/fix
if [ ! -d ./logs ]; then
  mkdir -p logs
fi

# Export the variables we will need in other tasks
envfile=HybridVar_run.env
cat > ${envfile} << EOF
RDASApp='${RDASApp}'
rrfsworkflow='${rrfsworkflow}'
rrfspath='${rrfspath}'
reflpath='${reflpath}'
obsbase='${obsbase}'
obspath='${obspath}'
baserundir='${`baserundir}'
enspath='${enspath}'
HH='${HH}'
YYYYMMDD='${YYYYMMDD}'
YYYY='${YYYY}'
MM='${MM}'
DD='${DD}'
bufrdir='${bufrdir}'
mrmsdir='${mrmsdir}'
anldir='${anldir}'
verifdir='${verifdir}'
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
rm -f bufr.log mrms.log getkf.log verif.log HybridVar.log
mkdir -p ${bufrdir}
mkdir -p ${mrmsdir}
mkdir -p ${anldir}
mkdir -p ${verifdir}
cp ${envfile} ${bufrdir}
cp ${envfile} ${mrmsdir}
cp ${envfile} ${anldir}
cp ${envfile} ${verifdir}
cp ./scripts/prep_ioda_cast.sh ${bufrdir}
cp ./scripts/prep_phydata_dbz.py ${anldir}
cp ./scripts/apply_jedi_incs.sh ${verifdir}

# Create radar observations
job1=$(bash "${submit}" \
    -N "${RADAR_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${RADAR_SELECT}" \
    -l "walltime=${RADAR_WALLTIME}" \
    -l "place=${RADAR_PLACE}" \
    -o "${RADAR_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${RADAR_PBS_NP},PBS_NUM_NODES=${RADAR_PBS_NUM_NODES}" \
    "${script_dir}/scripts/exrrfs_process_radar.sh")

# Convert prepbufr observations to IODA
job2=$(bash "${submit}" \
    -N "${BUFR_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${BUFR_SELECT}" \
    -l "walltime=${BUFR_WALLTIME}" \
    -l "place=${BUFR_PLACE}" \
    -o "${BUFR_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${BUFR_PBS_NP},PBS_NUM_NODES=${BUFR_PBS_NUM_NODES}" \
    "${script_dir}/scripts/exrrfs_ioda_bufr.sh")

# Run the GETKF analysis after both upstream jobs complete successfully
#    -W "depend=afterok:${job1}:${job2}" \
#    
cat > sub_hybridvar.sh << EOF
#!/bin/bash
# Debug resubmission script generated by DRIVER_HybridVar_analysis.sh.
# It can be rerun directly with:
#   qsub sub_hybridvar.sh
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

export envfile=${envfile}
export PBS_NP=${HybridVar_PBS_NP}
export PBS_NUM_NODES=${HybridVar_PBS_NUM_NODES}

cd "${currdir}"
exec bash "${script_dir}/scripts/exrrfs_analysis_HybridVar_jedi.sh"
EOF
chmod +x sub_hybridvar.sh
echo "Wrote debug HybridVar PBS script: ${currdir}/sub_hybridvar.sh"

job3=$(bash "${submit}" \
    -N "${HybridVar_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${HybridVar_SELECT}" \
    -l "walltime=${HybridVar_WALLTIME}" \
    -l "place=${HybridVar_PLACE}" \
    -o "${HybridVar_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${HybridVar_PBS_NP},PBS_NUM_NODES=${HybridVar_PBS_NUM_NODES}" \
    -W "depend=afterok:${job1}:${job2}" \
    "${script_dir}/scripts/exrrfs_analysis_jedi_mgbf.sh")

# Run the verification after the GETKF job completes successfully
job4=$(bash "${submit}" \
    -N "${VERIF_JOB_NAME}" \
    -A "${PBS_ACCOUNT}" \
    -q "${PBS_QUEUE}" \
    -l "select=${VERIF_SELECT}" \
    -l "walltime=${VERIF_WALLTIME}" \
    -l "place=${VERIF_PLACE}" \
    -o "${VERIF_LOG}" \
    -v "envfile=${envfile}" \
    -v "PBS_NP=${VERIF_PBS_NP},PBS_NUM_NODES=${VERIF_PBS_NUM_NODES}" \
    -W "depend=afterok:${job3}" \
    "${script_dir}/scripts/exrrfs_analysis_gsi.sh")

#cltorg echo "Submitted jobs: radar=${job1} bufr=${job2} getkf=${job3} verif=${job4}"
echo "Submitted jobs: radar=${job1} bufr=${job2} HybridVar=${job3} verif=${job4}"

# Wait for all jobs to complete
while qstat_output=$(qstat "${job1}" "${job2}" "${job3}" "${job4}" 2>/dev/null || true); do
    if [[ "${qstat_output}" != *"${job1}"* && \
          "${qstat_output}" != *"${job2}"* && \
          "${qstat_output}" != *"${job3}"* && \
          "${qstat_output}" != *"${job4}"* ]]; then
        break
    fi
    sleep 10
done

if [ -f bufr.log ]; then
    mv bufr.log logs/bufr_${YYYYMMDD}${HH}.log
fi
if [ -f mrms.log ]; then
    mv mrms.log logs/mrms_${YYYYMMDD}${HH}.log
fi
if [ -f HybridVar.log ]; then
    mv HybridVar.log logs/HybridVar_${YYYYMMDD}${HH}.log
fi
if [ -f verif.log ]; then
    mv verif.log logs/verif_${YYYYMMDD}${HH}.log
fi

exit 0
