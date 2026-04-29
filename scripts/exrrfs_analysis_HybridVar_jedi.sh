#!/bin/bash
################
### Settings ###
################

cd ${PBS_O_WORKDIR}
set -euox pipefail
echo ${envfile}
source "${envfile}"

nens=30
CRES="C3463"
output_ens="TRUE"
DO_ENKF_RADAR_REF="FALSE"
FIX_JEDI=${rrfsworkflow}/fix/jedi
FIX_GSI=${rrfsworkflow}/fix/gsi
PREDEF_GRID_NAME=RRFS_NA_3km
RDASAPP_DIR=${RDASApp}
PARM_IODACONV=${rrfsworkflow}/parm/iodaconv
PARMdir=${rrfsworkflow}/parm
USHdir=${rrfsworkflow}/ush
EXECdir=${rrfsworkflow}/exec
pgmout=${anldir}/pgm.log

#############################
### Begin executable code ###
#############################

cd ${anldir}
set +x
source ${rrfsworkflow}/versions/run.ver
module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
module load run_enkfupdt_jedi.local
ulimit -s unlimited
ulimit -v unlimited
ulimit -a
set -euox pipefail
export OOPS_TRACE=0
export LD_LIBRARY_PATH="${RDASAPP_DIR}/build/lib64:${LD_LIBRARY_PATH}"
export FI_MR_CACHE_MONITOR=memhooks
export FI_MR_CACHE_MAX_COUNT=0
export MPICH_ENV_DISPLAY=1
export MPICH_OFI_STARTUP_CONNECT=1
export MPICH_OFI_VERBOSE=1
export MPICH_MPIIO_HINTS='*.tile1.nc:romio_cb_read=disable,*.sfc_data.nc:romio_cb_read=disable,*.phy_data.nc:romio_cb_read=disable,*.fv_*.res.nc:romio_cb_write=enable,*.sfc_data.nc:romio_cb_write=enable'
export OMP_STACKSIZE=500M
export OMP_NUM_THREADS=1 #${TPP_RUN_ANALYSIS}
APRUN="mpirun -n $(( PBS_NP * PBS_NUM_NODES )) -ppn ${PBS_NP} --cpu-bind core --depth 1"

#
#-----------------------------------------------------------------------
#
# Define fix path
#
#-----------------------------------------------------------------------
#
fixgriddir=$FIX_GSI/${PREDEF_GRID_NAME}
cp ${fixgriddir}/fv3_coupler.res    coupler.res
cp ${fixgriddir}/fv3_akbk           fv3_akbk
cp ${fixgriddir}/fv3_grid_spec      fv3_grid_spec

# update times in coupler.res to current cycle time
sed -i "s/yyyy/${YYYY}/" coupler.res
sed -i "s/mm/${MM}/"     coupler.res
sed -i "s/dd/${DD}/"     coupler.res
sed -i "s/hh/${HH}/"     coupler.res
YYYYMMDDHH=${YYYYMMDD}${HH}
CDATE=${YYYYMMDD}${HH}
CDATE_M1=$(date +%Y%m%d%H -d "$(echo "${CDATE}" | sed 's/\([[:digit:]]\{2\}\)$/ \1/') 1 hour ago")
echo "thinkdeb CDATA/CDATA_M1 are "$CDATE ' ' $CDATE_M1
CDATE_M1_ISO=$(date -u -d "${CDATE_M1:0:8} ${CDATE_M1:8:2}:00:00" +"%Y-%m-%dT%H:%M:%SZ")


cp  example-HybridVar.yaml  HybridVar-jedi.yaml
sed -i "s|^\([[:space:]]*begin:[[:space:]]*\).*|\1${tCDATE_M1_ISO}|" HybridVar-jedi.yaml



#
#-----------------------------------------------------------------------
#
# Loop through the members, link the background into run directory
#
#-----------------------------------------------------------------------
#
mkdir -p data/inputs
for imem in  $(seq 1 $nens); do

  memchar="mem"$(printf %04i $imem)
  memcharv0="mem"$(printf %03i $imem)
  mem3=$(printf %03i $imem)
  slash_ensmem_subdir=$memchar
  #bkpath=${cycle_dir}/${slash_ensmem_subdir}/fcst_fv3lam/INPUT
  #bkpath=${enspath}/
  bkpath=${enspath}/m${mem3}/forecast/RESTART
  suffix=${YYYYMMDD}.${HH}0000.
  BKTYPE=0              # warm start
  mkdir -p data/inputs/${memcharv0}
  ln -snf ${bkpath}/${suffix}fv_core.res.tile1.nc       data/inputs/${memcharv0}/fv_core.res.tile1.nc
  ln -snf ${bkpath}/${suffix}fv_tracer.res.tile1.nc     data/inputs/${memcharv0}/fv_tracer.res.tile1.nc
  ln -snf ${bkpath}/${suffix}sfc_data.nc                data/inputs/${memcharv0}/sfc_data.nc
  ln -snf ${bkpath}/${suffix}phy_data.nc              data/inputs/${memcharv0}/phy_data.nc
  ln -snf ${bkpath}/${suffix}fv_srf_wnd.res.tile1.nc    data/inputs/${memcharv0}/fv_srf_wnd.res.tile1.nc
  ln -snf ${bkpath}/${suffix}coupler.res                data/inputs/${memcharv0}/coupler.res

done

#
#-----------------------------------------------------------------------
#
# Pre-process the phy_data for reflectivity assimilation
#
#-----------------------------------------------------------------------
#

# Verify all input files exist before starting parallel processing
echo "Verifying all input files are accessible..."
max_retries=5
retry_count=0
files_missing=true

while [ "$files_missing" = true ] && [ $retry_count -lt $max_retries ]; do
  files_missing=false
  for imem in $(seq 1 $nens); do
    memcharv0="mem"$(printf %03i $imem)
    if [ ! -f "data/inputs/${memcharv0}/phy_data.nc" ]; then
      echo "  WARNING: data/inputs/${memcharv0}/phy_data.nc not accessible yet (attempt $((retry_count+1))/$max_retries)"
      files_missing=true
    fi
  done

  if [ "$files_missing" = true ]; then
    if [ $retry_count -lt $((max_retries-1)) ]; then
      echo "  Waiting 10 seconds before retrying..."
      sleep 10
    else
      echo "ERROR: Input files still not accessible after $max_retries attempts. Aborting."
      exit 1
    fi
  fi
  retry_count=$((retry_count+1))
done

echo "All input files verified successfully!"
echo "Extracting ref_f3d and running prep_phydata_dbz.py in parallel for all members..."
for imem in $(seq 1 $nens); do
  memcharv0="mem"$(printf %03i $imem)
  echo "ncks -O -v ref_f3d data/inputs/${memcharv0}/phy_data.nc data/inputs/${memcharv0}/phy_data.nc_prepdbz > prep_phydata_${memcharv0}.log 2>&1 && python prep_phydata_dbz.py data/inputs/${memcharv0}/phy_data.nc_prepdbz >> prep_phydata_${memcharv0}.log 2>&1"
done | parallel -j 30 --halt soon,fail=1
echo "phy_data.nc preprocessing completed successfully!!!"

# View timing for all members
echo "Timing summary:"
grep "Total time" prep_phydata_*.log


#clt skipt the original jcb block now only use sed to replace time related string in an template yaml
#
#-----------------------------------------------------------------------
#
# JCB - JEDI Configuration Builder
#
#-----------------------------------------------------------------------



#
#-----------------------------------------------------------------------
#
# link observation files
# copy observation files to working directory
#
#-----------------------------------------------------------------------
#
mkdir -p data/obs
cp ${bufrdir}/ioda_*.nc data/obs/.
cp ${mrmsdir}/00/ioda_mrms_${YYYYMMDD}${HH}_00.nc4 data/obs/ioda_mrms_refl.nc

#
#-----------------------------------------------------------------------
#
# Copy in other fix files needed
#
#-----------------------------------------------------------------------
#
echo "thinkdeb " `pwd`
mkdir -p INPUT
FIXLAM=/lfs/h2/emc/da/noscrub/samuel.degelia/rrfs-workflow_na3km/rrfs-workflow/fix/lam/RRFS_NA_3km
ln -snf ${FIXLAM}/${CRES}_grid.tile7.halo3.nc INPUT/${CRES}_grid.tile7.halo3.nc
ln -snf ${FIXLAM}/${CRES}_grid.tile7.halo3.nc INPUT/${CRES}_grid.tile7.nc
ln -snf ${FIXLAM}/${CRES}_mosaic.halo3.nc INPUT/grid_spec.nc
cp ${FIX_JEDI}/dynamics_lam_cmaq.yaml .
cp ${FIX_JEDI}/field_table .
cp ${FIX_JEDI}/${PREDEF_GRID_NAME}/fmsmpp.nml .
#cp ${FIX_JEDI}/${PREDEF_GRID_NAME}/input_lam* .
cp ${fixsimple}/input_lam* .

#

#
#-----------------------------------------------------------------------
#
# Run JEDI-based EnKF
#
#-----------------------------------------------------------------------
#
#export OOPS_TRACE=1
#export OOPS_DEBUG=1
export OMP_NUM_THREADS=1
export pgm="fv3jedi_var.x"
#jedi_exec="${EXECdir}/bin/${pgm}"
jedi_exec="${RDASAPP_DIR}/build/bin/${pgm}"
cp "${jedi_exec}" "${anldir}/${pgm}"

. prep_step

${APRUN} ./$pgm HybridVar-jedi.yaml >>$pgmout 2>errfile
export err=$?; err_chk
#cp $pgmout ${COMOUT}/rrfs.t${HH}z.jediout_observer.tm00
#cp ${JCB_CONFIG_ENKF_OBSERVER} ${COMOUT}
#cp jedienkf_observer.yaml ${COMOUT}/jedienkf_observer.yaml
mv errfile errfile_jedi_enkf

echo "JEDI-HybridVar PROCESS completed successfully!!!"
