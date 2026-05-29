#!/bin/bash
################
### Settings ###
################

cd ${PBS_O_WORKDIR}
set -euox pipefail
source "${envfile}"

RADAR_REF_THINNING=2 # used for enkf
RADARREFL_TIMELEVEL=( "0" )
RADARREFL_MINS=( \
"0" \
"1" \
"2" \
"3" \
)
FIX_GSI=${rrfsworkflow}/fix/gsi
PREDEF_GRID_NAME=RRFS_NA_3km
pgmout=${mrmsdir}/pgm.log

#############################
### Begin executable code ###
#############################

rrfsworkflow=/lfs/h2/emc/da/noscrub/samuel.degelia/rrfs-workflow_na3km/rrfs-workflow  #cltthinkdeb
source ${rrfsworkflow}/versions/run.ver
set +x
module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
module load run_analysis_gsi.local
ulimit -s unlimited
ulimit -a
set -euox pipefail
APRUN="mpiexec -n $(( PBS_NP * PBS_NUM_NODES )) -ppn ${PBS_NP}"

#
#-----------------------------------------------------------------------
#
# Loop through different time levels
# Get into working directory
#
#-----------------------------------------------------------------------
#
YYYYMMDDHH=${YYYYMMDD}${HH}
export pgm="process_NSSL_mosaic.exe"
for bigmin in ${RADARREFL_TIMELEVEL[@]}; do
  bigmin=$( printf %2.2i $bigmin )
  mkdir -p ${mrmsdir}/${bigmin}
  cd ${mrmsdir}/${bigmin}

  fixdir=$FIX_GSI/
  fixgriddir=$FIX_GSI/${PREDEF_GRID_NAME}

  #
  #-----------------------------------------------------------------------
  #  
  # link or copy background files
  #
  #-----------------------------------------------------------------------
  #
  cp ${fixgriddir}/fv3_grid_spec  fv3sar_grid_spec.nc
  #
  #-----------------------------------------------------------------------
  #
  # link/copy observation files to working directory 
  #
  #-----------------------------------------------------------------------
  #
  obs_appendix=grib2.gz
  NSSL=${reflpath}
  mrms="MergedReflectivityQC"
  #
  #-----------------------------------------------------------------------
  #
  # Link to the MRMS operational data
  #
  #-----------------------------------------------------------------------
  #
  echo "bigmin = ${bigmin}"
  echo "RADARREFL_MINS = ${RADARREFL_MINS[@]}"
  #
  #-----------------------------------------------------------------------
  #
  # Link to the MRMS operational data
  #
  #-----------------------------------------------------------------------
  #
  for min in ${RADARREFL_MINS[@]}
  do
    min=$( printf %2.2i $((bigmin+min)) )
    echo "Looking for data valid:"${YYYY}"-"${MM}"-"${DD}" "${HH}":"${min}
    s=0
    while [[ $s -le 59 ]]; do
      ss=$(printf %2.2i ${s})
      nsslfile=${NSSL}/*${mrms}_00.50_${YYYY}${MM}${DD}-${HH}${min}${ss}.${obs_appendix}
      echo ${nsslfile}
      if [ -s $nsslfile ]; then
        echo 'Found '${nsslfile}
        nsslfile1=*${mrms}_*_${YYYY}${MM}${DD}-${HH}${min}*.${obs_appendix}
        numgrib2=$(ls ${NSSL}/${nsslfile1} | wc -l)
        echo 'Number of GRIB-2 files: '${numgrib2}
        if [ ${numgrib2} -ge 10 ] && [ ! -e filelist_mrms ]; then
          cp ${NSSL}/${nsslfile1} . 
          ls ${nsslfile1} > filelist_mrms 
          echo 'Creating links for ${YYYY}${MM}${DD}-${HH}${min}'
        fi
      fi
      ((s+=1))
    done
  done
  #
  #-----------------------------------------------------------------------
  #
  # remove filelist_mrms if zero bytes
  #
  #-----------------------------------------------------------------------
  #
  if [ ! -s filelist_mrms ]; then
    rm -f filelist_mrms
  fi

  if [ -s filelist_mrms ]; then
     if [ ${obs_appendix} == "grib2.gz" ]; then
        gzip -d *.gz
        mv filelist_mrms filelist_mrms_org
        ls MergedReflectivityQC_*_${YYYY}${MM}${DD}-${HH}????.grib2 > filelist_mrms
     fi
     numgrib2=$(more filelist_mrms | wc -l)
  else
     echo "WARNING: Not enough radar reflectivity files available for loop ${bigmin}."
     continue
  fi
  #
  #-----------------------------------------------------------------------
  #
  # copy bufr table from fix directory
  #
  #-----------------------------------------------------------------------
  BUFR_TABLE=${fixdir}/prepobs_prep_RAP.bufrtable
  cp $BUFR_TABLE prepobs_prep.bufrtable
  #
  #-----------------------------------------------------------------------
  #
  # Build namelist and run executable 
  #
  #   tversion      : data source version
  #                   = 1 NSSL 1 tile grib2 for single level
  #                   = 4 NSSL 4 tiles binary
  #                   = 8 NSSL 8 tiles netcdf
  #   fv3_io_layout_y : subdomain of restart files
  #   analysis_time : process obs used for this analysis date (YYYYMMDDHH)
  #   dataPath      : path of the radar reflectivity mosaic files.
  #
  #-----------------------------------------------------------------------
  #
  n_iolayouty=1

cat << EOF > namelist.mosaic
   &setup
    tversion=1,
    analysis_time = ${YYYYMMDDHH},
    dataPath = './',
    fv3_io_layout_y=${n_iolayouty},
   /
EOF

  if [ ${RADAR_REF_THINNING} -eq 2 ]; then
    # heavy data thinning, typically used for EnKF
    precipdbzhorizskip=1
    precipdbzvertskip=2
    clearairdbzhorizskip=2
    clearairdbzvertskip=4
  else
    if [ ${RADAR_REF_THINNING} -eq 1 ]; then
      # light data thinning, typically used for hybrid EnVar
      precipdbzhorizskip=1
      precipdbzvertskip=1
      clearairdbzhorizskip=1
      clearairdbzvertskip=1
    else
      # no data thinning
      precipdbzhorizskip=0
      precipdbzvertskip=0
      clearairdbzhorizskip=0
      clearairdbzvertskip=0
    fi
  fi

cat << EOF > namelist.mosaic_netcdf
   &setup_netcdf
    output_netcdf = .true.,
    max_height = 11001.0,
    use_clear_air_type = .true.,
    precip_dbz_thresh = 10.0,
    clear_air_dbz_thresh = 5.0,
    clear_air_dbz_value = 0.0,
    precip_dbz_horiz_skip = ${precipdbzhorizskip},
    precip_dbz_vert_skip = ${precipdbzvertskip},
    clear_air_dbz_horiz_skip = ${clearairdbzhorizskip},
    clear_air_dbz_vert_skip = ${clearairdbzvertskip},
   / 
EOF
  #
  #-----------------------------------------------------------------------
  #
  # Run the radar refl process.
  #
  #-----------------------------------------------------------------------
  #
  EXECdir=${rrfsworkflow}/exec
  $APRUN ${EXECdir}/$pgm >>$pgmout 2>errfile

  cp RefInGSI3D.dat  ./rrfs.t${HH}z.RefInGSI3D.bin.${bigmin}

  #
  #------------------------------------------------------------------------
  #
  # Now convert the binary reflectivity data to IODA format
  #
  #------------------------------------------------------------------------
  #


   # pyioda libraries
   set +x
#clt   module purge
   module reset
   #cltorg
   #cltRDASAPP_DIR=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_iodafix/RDASApp #thinkdeb
   RDASAPP_DIR=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-rdasapp/RADASApp #thinkdeb
#clt   RDASApp=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_iodafix/RDASApp  #cltthinkdeb
   RDASApp=/lfs/h2/emc/da/noscrub/Ting.Lei/dr-rdasapp/RDASApp
   module use "${RDASApp}"/modulefiles
   module load RDAS/wcoss2.intel
   set -euox pipefail
   PYIODALIB=$(echo "${RDASApp}"/build/lib/python3.*)
   export PYTHONPATH=${PYIODALIB}:${PYTHONPATH}
   "${rrfsworkflow}"/ush/MRMS2ioda.py -i ./Gridded_ref.nc -c "${YYYY}-${MM}-${DD}T${HH}:${bigmin}:00" -o "ioda_mrms_${YYYYMMDD}${HH}_${bigmin}.nc4"

   # file count sanity check and copy to COMOUT
   if [[ -s "ioda_mrms_${YYYYMMDD}${HH}_${bigmin}.nc4" ]]; then
     echo "SUCCESS: ioda_mrms_${YYYYMMDD}${HH}_${bigmin}.nc4 created"
   else
     echo "FATAL ERROR: no ioda MRMS file generated."
     exit
   fi


done # done with the bigmin for-loop
#
#-----------------------------------------------------------------------
#
# Print message indicating successful completion of script.
#
#-----------------------------------------------------------------------
#
echo RADAR REFL PROCESS completed successfully!!!
