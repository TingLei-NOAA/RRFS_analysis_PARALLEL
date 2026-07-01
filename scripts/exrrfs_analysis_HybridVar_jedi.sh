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

echo "Changing to HybridVar analysis directory: ${anldir}"
cd ${anldir}
echo "Current working directory after cd: $(pwd)"
set +x
#source ${rrfsworkflow}/versions/run.ver
#module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
#module load run_enkfupdt_jedi.local
jedi_bundle=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-jedi-bundle/jedi-bundle
rdasapp_build_dir="/lfs/h2/emc/da/noscrub/Ting.Lei/dr-rdasapp/RDASApp/build"
moduledir="/lfs/h2/emc/da/noscrub/Ting.Lei/dr-rdasapp/RDASApp/modulefiles"
module use $moduledir
module load RDAS/wcoss2.intel
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/opt/cray/pe/mpich/8.1.19/ofi/intel/19.0/lib"
#clt export JEDI_LIBS="${jedi_bundle}/build/lib64:${jedi_bundle}/build/lib"
export rdasapp_LIBS="${rdasapp_build_dir}/lib64:${rdasapp_build_dir}/lib"
#clt module load intel-oneapi-mkl intel-oneapi-compiler
#export LD_LIBRARY_PATH="$JEDI_LIBS:$MKLROOT/lib/intel64:$LD_LIBRARY_PATH"
#export LD_LIBRARY_PATH="$JEDI_LIBS:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$rdasapp_LIBS:$LD_LIBRARY_PATH"

ulimit -s unlimited
ulimit -v unlimited
ulimit -a
set -euox pipefail
export OMP_NUM_THREADS=1
export OMP_PLACES=cores
export OMP_PROC_BIND=close
export OMP_STACKSIZE=1G
export FI_MR_CACHE_MONITOR=memhooks
export FI_MR_CACHE_MAX_COUNT=0
export MPICH_OFI_STARTUP_CONNECT=1
export MPICH_OFI_VERBOSE=1
export MPICH_MPIIO_HINTS='*.tile1.nc:romio_cb_read=disable,...'


#clt export LD_LIBRARY_PATH="$JEDI_LIBS:$MKLROOT/lib/intel64:$LD_LIBRARY_PATH"

APRUN="mpiexec -l --line-buffer -n 1936 -ppn 32 --cpu-bind core --depth 4 --label -env LD_LIBRARY_PATH $LD_LIBRARY_PATH"



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
CDATE_ISO=$(date -u -d "${CDATE:0:8} ${CDATE:8:2}:00:00" +"%Y-%m-%dT%H:%M:%SZ")





#
#-----------------------------------------------------------------------
#
# Loop through the members, link the background into run directory
#
#-----------------------------------------------------------------------
#
#
echo thinkdeb pwdir
pwd 
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
#-----------------------------------------------------------------------
#
#  link the background into run directory
#
#-----------------------------------------------------------------------
#
  mkdir -p data/inputs/bkg
  bkpath=${controlpath}/forecast/RESTART
  suffix=${YYYYMMDD}.${HH}0000.
  BKTYPE=0              # warm start
  ln -snf ${bkpath}/${suffix}fv_core.res.tile1.nc       data/inputs/bkg/fv_core.res.tile1.nc
  ln -snf ${bkpath}/${suffix}fv_tracer.res.tile1.nc     data/inputs/bkg/fv_tracer.res.tile1.nc
  ln -snf ${bkpath}/${suffix}sfc_data.nc                data/inputs/bkg/sfc_data.nc
  ln -snf ${bkpath}/${suffix}phy_data.nc              data/inputs/bkg/phy_data.nc
  ln -snf ${bkpath}/${suffix}fv_srf_wnd.res.tile1.nc    data/inputs/bkg/fv_srf_wnd.res.tile1.nc
  ln -snf ${bkpath}/${suffix}coupler.res                data/inputs/bkg/coupler.res


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
cp ${fixsimple}/3kmNA_p1936_input.nml ./INPUT/
cp ${fixsimple}/dr-mgbf/${example:-example-hyb-vdl_v1-p1936.yaml}  HybridVar-jedi.yaml 
mkdir -p dr-mgbf-fix
cp ${fixsimple}/dr-mgbf/norm-sdl_vdl_v1_init-p1936.nml ./dr-mgbf-fix/
cp ${fixsimple}/dr-mgbf/norm-dbz-1G-2var_group_p1936.nml ./dr-mgbf-fix/
cp ${fixsimple}/dr-mgbf/norm-non_dbz-6var_group_p1936.nml ./dr-mgbf-fix/

cp ${fixsimple}/gsiparm_regional.anl .
cp ${fixsimple}/fv3_grid_spec .
cp ${fixsimple}/berror_stats .

ln -sf ${fixsimple}/dr-mgbf/dr-norm*var .
sed -i "s|^\([[:space:]]*begin:[[:space:]]*\).*|\1${CDATE_M1_ISO}|" HybridVar-jedi.yaml
sed -i "s|datetime: &analysisDate .*|datetime: \&analysisDate ${CDATE_ISO}|" HybridVar-jedi.yaml 

ln -sf ${fixsimple}/DataFix .

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
jedi_exec="${jedi_bundle}/build/bin/${pgm}"
jedi_exec="${rdasapp_build_dir}/bin/${pgm}"
cp "${jedi_exec}" "${anldir}/${pgm}"

. prep_step

${APRUN} ./$pgm HybridVar-jedi.yaml >>$pgmout 2>errfile
dir_save_stats="/u/ting.lei/dr-3kmNA-parallel/dr_save_stats"
mkdir -p $dir_save_stats
cp $controlpath/analysis/*gsiout*  ${dir_save_stats}/gsi_out_$CDATE
cp $pgmout ${dir_save_stats}/jedi_out$CDATE
export err=$?; err_chk
#cp $pgmout ${COMOUT}/rrfs.t${HH}z.jediout_observer.tm00
#cp ${JCB_CONFIG_ENKF_OBSERVER} ${COMOUT}
#cp jedienkf_observer.yaml ${COMOUT}/jedienkf_observer.yaml
mv errfile errfile_jedi_hyb
#mkdir -p $verfidir/dr-diag
#cltcp j*diag*  ${verfidir}/dr-diag/

echo "JEDI-HybridVar PROCESS completed successfully!!!"
