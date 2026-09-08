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

echo "Changing to HybridVar verif directory: ${verifdir}"
cd ${verifdir}
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
#
# controlpath is the control cycle directory <com_root>/rrfs.YYYYMMDD/HH, e.g.
# /lfs/h1/ops/para/com/rrfs/v1.0/rrfs.20260810/10. Its forecast/RESTART files are
# valid one hour later, so the analysis time is that cycle time plus one hour.
# controlpath_analysis is the control directory for that analysis time, e.g.
# /lfs/h1/ops/para/com/rrfs/v1.0/rrfs.20260810/11
#
control_cycle_hh=${controlpath##*/}
control_cycle_dir=${controlpath%/*}
control_cycle_ymd=${control_cycle_dir##*.}
control_com_root=${control_cycle_dir%/*}
control_com_prefix=${control_cycle_dir##*/}
control_com_prefix=${control_com_prefix%%.*}
if ! [[ ${control_cycle_ymd} =~ ^[0-9]{8}$ && ${control_cycle_hh} =~ ^[0-9]{2}$ ]]; then
  echo "ERROR: unable to parse cycle time from controlpath: ${controlpath}" >&2
  exit 1
fi
control_cycle_epoch=$(date -u -d "${control_cycle_ymd:0:4}-${control_cycle_ymd:4:2}-${control_cycle_ymd:6:2} ${control_cycle_hh}:00:00" +%s)
CDATE=$(date -u -d "@$((control_cycle_epoch + 3600))" +%Y%m%d%H)
controlpath_analysis=${control_com_root}/${control_com_prefix}.${CDATE:0:8}/${CDATE:8:2}
if [[ "${CDATE}" != "${YYYYMMDDHH}" ]]; then
  echo "WARNING: analysis time from controlpath (${CDATE}) differs from the enspath valid time (${YYYYMMDDHH})"
fi
echo "thinkdeb controlpath=${controlpath} controlpath_analysis=${controlpath_analysis} CDATE=${CDATE}"
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
  gsianl_dir=$controlpath_analysis/analysis
  gsifcst_dir=$controlpath_analysis/forecast/RESTART
  gsifcstinput_dir=$controlpath_analysis/forecast/INPUT 
  YYYYMMDD_anal=${CDATE:0:8}
  HH_anal=${CDATE:8:2}
  suffix_anal=${YYYYMMDD_anal}.${HH_anal}0000.

  


  mkdir -p dr-cmp_rundir 
  cd dr-cmp_rundir
  cp ${gsianl_dir}/diag*conv*nc* .
  cp ${gsianl_dir}/*fit* .
#cltorg  cp $anldir/j*diag*nc* .   # jedi diag outptu 
  jdiag_dir=./dir-jdiag_dir
  mkdir -p ${jdiag_dir}
  rundir=`pwd`
  cp $anldir/j*diag*nc* ${jdiag_dir}/ # jedi diag outptu 
  cd $jdiag_dir
  export JEDI_BUNDLE=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-jedi-bundle/jedi-bundle
  export PYTHONPATH=${JEDI_BUNDLE}/ioda/src/python:${PYTHONPATH}
  mkdir -p ../jdiag_merged

  for first_file in *_0000.nc; do
    ob_string="${first_file%_0000.nc}"
    files=( "${ob_string}"_[0-9][0-9][0-9][0-9].nc )

    echo "Merging ${ob_string}"

    python ${JEDI_BUNDLE}/ioda/test/python/pyiodautils/test_file_merge_concat_method.py \
      --outfile "../jdiag_merged/${ob_string}.nc" \
      --infiles "${files[@]}" \
    && rm -f "${files[@]}"
  done
  mkdir -p dr-bg_analysis
  cd dr-bg_analysis
  cp -L ${gsifcstinput_dir}/fv_core.res.tile1.nc      gsi_anl_fv_core.res.tile1.nc
  cp -L  ${gsifcstinput_dir}/fv_tracer.res.tile1.nc     gsi_anl_fv_tracer.res.tile1.nc
  cp -L  ${gsifcstinput_dir}/phy_data.nc     gsi_anl_phy_data.nc
  cp -L  $anldir/data/inputs/bkg/fv_core.res.tile1.nc  jedi_bg_fv_core.res.tile1.nc
  cp -L  $anldir/data/inputs/bkg/fv_tracer.res.tile1.nc  jedi_bg_fv_tracer.res.tile1.nc
  cp -L  $anldir/data/inputs/bkg/phy_data.nc  jedi_bg_phy_data.nc
  cp $anldir/p1936-hyb-norm-vdl*.nc . # the analysis of jedi
   
  cd ..



  cd $rundir

  gzip -df *.gz
  ${script_dir}/run_convert_gsi_diag_to_gdiag.sh $CDATE .
  status=$?

if [ $status -ne 0 ]; then
    echo "ERROR: run_convert_gsi_diag_to_gdiag.sh failed with exit code $status"
    exit $status
fi
  python ${rdas_rrfs_script}/diff_profile_rms_bias_fit.py GSI JEDI ./jdiag*.nc --  jdiag_merged/jdiag*.nc
dr_store_verif="/lfs/h2/emc/da/noscrub/Ting.Lei/dr-hybrid-parallel-store"
dr_cycle_store=${dr_store_verif}/$CDATE
mkdir -p $dr_cycle_store
cp -r ../dr-cmp_rundir $dr_cycle_store


    
   
