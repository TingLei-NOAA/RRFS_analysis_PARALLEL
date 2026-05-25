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
moduledir="/lfs/h2/emc/da/noscrub/Ting.Lei/dr-rdasapp/RDASApp/modulefiles"
module use $moduledir
module load RDAS/wcoss2.intel
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/opt/cray/pe/mpich/8.1.19/ofi/intel/19.0/lib"
ulimit -s unlimited
ulimit -v unlimited
ulimit -a
set -euox pipefail
jedi_bundle=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-jedi-bundle/jedi-bundle
export OMP_NUM_THREADS=1
export OMP_PLACES=cores
export OMP_PROC_BIND=close
export OMP_STACKSIZE=1G

export JEDI_LIBS="${jedi_bundle}/build/lib64:${jedi_bundle}/build/lib"
export LD_LIBRARY_PATH="$JEDI_LIBS:$MKLROOT/lib/intel64:$LD_LIBRARY_PATH"

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


script_dir="/u/ting.lei/dr-3kmNA-parallel/RRFS_analysis_PARALLEL/scripts"


#
#-----------------------------------------------------------------------
#
# Loop through the members, link the background into run directory
#
#-----------------------------------------------------------------------
#
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

#clt 
  rdas_rrfs_script=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-rdasapp/RDASApp/rrfs-test/ush/diagnostics_and_graphics
  gsianl_dir=$controlpath/analysis
  mkdir -p dr-cmp_rundir 
  cd dr-cmp_rundir
  cp ${gsianl_dir}/diag*conv*nc* .
  cp $anldir/j*diag*nc* .   # jedi diag outptu 

  gzip -df *.gz
  ${script_dir}/run_convert_gsi_diag_to_gdiag.sh $CDATE .
  status=$?

if [ $status -ne 0 ]; then
    echo "ERROR: run_convert_gsi_diag_to_gdiag.sh failed with exit code $status"
    exit $status
fi
  python ${rdas_rrfs_script}/diff_profile_rms_bias_fit.py GSI JEDI ./jdiag*.nc  $jdiag_dir/jdiag*.nc


    
   
