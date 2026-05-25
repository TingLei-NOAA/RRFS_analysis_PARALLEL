#!/bin/bash
################
### Settings ###
################

cd ${PBS_O_WORKDIR}
set -euox pipefail
echo ${envfile}
source "${envfile}"

DO_SATRAD="FALSE"
FIX_JEDI=${rrfsworkflow}/fix/jedi
FIX_GSI=${rrfsworkflow}/fix/gsi
PREDEF_GRID_NAME=RRFS_NA_3km
#cltorg RDASAPP_DIR=${RDASApp}
RDASAPP=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_iodafix/RDASApp
RDASAPP_DIR=/lfs/h2/emc/da/noscrub/samuel.degelia/RDASApp_redist_iodafix/RDASApp
PARM_IODACONV=${rrfsworkflow}/parm/iodaconv
EXECdir=${rrfsworkflow}/exec
pgmout=${bufrdir}/pgm.log

#############################
### Begin executable code ###
#############################

cd ${bufrdir}
set +x
#clt module purge
module reset 
#cltorg source ${rrfsworkflow}/versions/run.ver
#cltorg
rrfsworkflow=/lfs/h2/emc/da/noscrub/samuel.degelia/rrfs-workflow_na3km/rrfs-workflow
source ${rrfsworkflow}/versions/run.ver
module use ${rrfsworkflow}/modulefiles/tasks/wcoss2
module load run_ioda_bufr.local
ulimit -s unlimited
ulimit -a
set -euox pipefail
APRUN="mpiexec -n 1 -ppn 1"

#
#-----------------------------------------------------------------------
#
# Extract from CDATE the starting year, month, day, and hour of the
# forecast.  These are needed below for various operations.
#
#-----------------------------------------------------------------------
#
YYYYMMDDHH=${YYYYMMDD}${HH}
CDATE=${YYYYMMDD}${HH}
START_DATE=$(echo "${CDATE}" | sed 's/\([[:digit:]]\{2\}\)$/ \1/')
YYYYMMDDHHm1=$(date +%Y%m%d%H -d "${START_DATE} 1 hour ago")
JJJ=$(date +%j -d "${START_DATE}")
YYJJJHH=$(date +"%y%j%H" -d "${START_DATE}")
PREYYJJJHH=$(date +"%y%j%H" -d "${START_DATE} 1 hours ago")
export PDY=${YYYYMMDD}

#
#
#-----------------------------------------------------------------------
#
# check the existence of the PrepBUFR file for the current cycle,
# if the file is present, convert the data into ioda format for
# aircraft, ascatw, gpsipw, mesonet, profiler, rassda,
# satwnd, surface, upperair subsets.
#
#-----------------------------------------------------------------------
#
OBSPATH=${obspath}
run_process_prepbufr=false
obs_file=prepbufr
checkfile=${OBSPATH}/rrfs.t${HH}z.prepbufr.tm00 # do not have access to this file
if [ -r "${checkfile}" ]; then
  echo "Found ${checkfile}; Use it as observation "
  cp -p ${checkfile} ${obs_file}
  run_process_prepbufr=true
else
  echo "Warning: PrepBUFR file for ${YYYYMMDDHH} does not exist!"
fi
#
#-----------------------------------------------------------------------
#
# Copy all bufr files to be converted to ioda format
#
#-----------------------------------------------------------------------
#
export cyc=${HH}
cp "${OBSPATH}/rrfs.t${cyc}z.satwnd.tm00.bufr_d" satwndbufr
cp "${OBSPATH}/rrfs.t${cyc}z.gsrcsr.tm00.bufr_d" abibufr
cp "${OBSPATH}/rrfs.t${cyc}z.atms.tm00.bufr_d" atmsbufr
cp "${OBSPATH}/rrfs.t${cyc}z.crisf4.tm00.bufr_d" crisfsbufr
#
#-----------------------------------------------------------------------
#
# Modify yaml template and run bufr2ioda (prepbufr)
#
#-----------------------------------------------------------------------
#
set +e
export LD_LIBRARY_PATH="${RDASApp}/build/lib64:${LD_LIBRARY_PATH}"

yaml_list=(
"prepbufr_adpsfc.yaml"
#"prepbufr_adpupa.yaml"  # use python
"prepbufr_aircar.yaml"
"prepbufr_aircft.yaml"
"prepbufr_ascatw.yaml"
"prepbufr_msonet.yaml"
"prepbufr_proflr.yaml"
"prepbufr_rassda.yaml"
"prepbufr_sfcshp.yaml"
"prepbufr_vadwnd.yaml"
)

export pgm="bufr2ioda.x"
formatted_time=$(date -d"${YYYYMMDDHH:0:8} ${YYYYMMDDHH:8:2}" '+%Y-%m-%dT%H:%M:%SZ')
for yamlfile in "${yaml_list[@]}"; do
  message_type=$(basename "$yamlfile" .yaml | awk -F'_' '{print $NF}')
  cp -p ${PARM_IODACONV}/${yamlfile} .
  sed -i "s/@referenceTime@/${formatted_time}/" "${yamlfile}"
  cp -p ${FIX_JEDI}/ioda_empty.nc  ioda_${message_type}.nc
  if [[ ${run_process_prepbufr} ]]; then
    ${EXECdir}/bin/$pgm ${yamlfile} >> $pgmout 2>&1
    export err=$?
    if [ $err -ne 0 ]; then
      if tail -20 $pgmout | grep -qF "No valid BUFR subsets were found"; then
        echo "WARNING: ${message_type}: no valid BUFR subsets in input. Skipping this type." >> "${pgmout}"
        export err=0
      else
        echo "ERROR: ${message_type} failed with error code $err" >> "${pgmout}"
        # Continue to next iteration or break here if you want to exit
      fi
    fi
  fi
done
set -e
#
#-----------------------------------------------------------------------
#
# run the python bufr2ioda tools
#
#-----------------------------------------------------------------------
#
export PYTHONUNBUFFERED=1

# pyioda libraries
shopt -s nullglob
dirs=("$RDASAPP_DIR"/build/lib/python3.*)
PYIODALIB=${dirs[0]}
WXFLOWLIB=${RDASAPP_DIR}/sorc/wxflow/src
export PYTHONPATH="${WXFLOWLIB}:${PYIODALIB}:${PYTHONPATH}"

cp "${RDASAPP_DIR}"/rrfs-test/IODA/python/bufr2ioda_adpupa_prepbufr.json .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/python/bufr2ioda_adpupa_prepbufr.py .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/python/bufr2ioda_satwnd_amv_goes.json .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/python/bufr2ioda_satwnd_amv_goes.py .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/python/bufr2ioda_gsrcsr.json .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/python/bufr2ioda_gsrcsr.py .

# generate a JSON w CDATE from the template and convert to IODA
cp "${RDASAPP_DIR}"/rrfs-test/IODA/python/gen_bufr2ioda_json.py .
which python
python -V 
python3 -V 
# ADPUPA (surface pressure)
cp -p ${FIX_JEDI}/ioda_empty.nc ioda_adpupa.nc
./gen_bufr2ioda_json.py -t bufr2ioda_adpupa_prepbufr.json -o bufr2ioda_adpupa_prepbufr_0.json
./bufr2ioda_adpupa_prepbufr.py -c bufr2ioda_adpupa_prepbufr_0.json >> $pgmout

# SATWND
cp -p ${FIX_JEDI}/ioda_empty_satwnd.nc ioda_satwnd.abi_goes-16.nc
cp -p ${FIX_JEDI}/ioda_empty_satwnd.nc ioda_satwnd.abi_goes-18.nc
./gen_bufr2ioda_json.py -t bufr2ioda_satwnd_amv_goes.json -o bufr2ioda_satwnd_amv_goes_0.json
./bufr2ioda_satwnd_amv_goes.py -c bufr2ioda_satwnd_amv_goes_0.json >> $pgmout

# Satellite Radiance
if [ $DO_SATRAD == "TRUE" ]; then

  #1 ABI GSRCSR
  # --------------------------------------------------
  # run  bufr2netcdf tool for abi csr bufr obs
  # --------------------------------------------------
  ./gen_bufr2ioda_json.py -t bufr2ioda_gsrcsr.json -o bufr2ioda_gsrcsr_0.json
  ./bufr2ioda_gsrcsr.py -c bufr2ioda_gsrcsr_0.json >> $pgmout

  #2 ATMS
  # --------------------------------------------------
  # run  bufr2netcdf tool for atms bufr obs
  # --------------------------------------------------
  cp "${FIX_JEDI}/atms_beamwidth.txt" .
  cp "${PARM_IODACONV}/bufr_atms_mapping.yaml" .
  input_file="atmsbufr"
  output_file="ioda_atms_{splits/satId}.nc"
  yaml="bufr_atms_mapping.yaml"
  if [[ -f "$input_file" ]]; then
    ${EXECdir}/bin/bufr2netcdf.x "$input_file" "$yaml" "$output_file"
  else
    echo "Input file $input_file does not exist."
  fi

  #3 AMSUA

  #4 CRIS
  # --------------------------------------------------
  # run  bufr2netcdf tool for cris-fsr bufr obs
  # --------------------------------------------------
  cp "${PARM_IODACONV}/bufr2netcdf_cris-fsr.yaml" .
  input_file="crisfsbufr"
  output_file="ioda_crisf4_{splits/satId}.nc"
  yaml="bufr2netcdf_cris-fsr.yaml"

  if [[ -f "$input_file" ]]; then
    ${EXECdir}/bin/bufr2netcdf.x "$input_file" "$yaml" "$output_file"
  else
    echo "Input file $input_file does not exist."
  fi

fi

#
#-----------------------------------------------------------------------
#
# Run the IODA offline tools
#
#-----------------------------------------------------------------------
#
is_empty_ioda() {
    local f="$1"
    # Robust check: look at Location dimension
    local loc
    loc=$(ncdump -h "$f" 2>/dev/null | awk '/Location =/ {print $3}' | tr -d ';')
    if [ -z "$loc" ]; then
        return 0
    fi
    if [ "$loc" -le 1 ]; then
        return 0  # empty
    fi
    return 1  # not empty
}

cp "${RDASAPP_DIR}"/rrfs-test/IODA/offline_domain_check.py .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/offline_domain_check_satrad.py .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/offline_ioda_patch.py .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/offline_vad_thinning.py .
cp "${RDASAPP_DIR}"/rrfs-test/IODA/offline_duplicate_tagger.py .

# offline domain check & patch
for ioda_file in ioda*.nc; do
  # skip empty files
  if is_empty_ioda "$ioda_file"; then
    echo "Skipping domain check & patch: $ioda_file is empty"
    continue
  fi
  grid_file="${FIX_GSI}/${PREDEF_GRID_NAME}/fv3_grid_spec"
  if [[ "${ioda_file}" == *abi* && "${ioda_file}" != *satwnd* ]]; then
    echo " ${ioda_file} ioda file detected: running offline_domain_check_satrad.py"
    export pgm="offline_domain_check_satrad.py"
    ./offline_domain_check_satrad.py -o "${ioda_file}" -g "${grid_file}" -s 0.005 >> $pgmout
    #export err=$?; err_chk
    base_name=$(basename "$ioda_file" .nc)
    mv  "${base_name}_dc.nc" "${base_name}.nc"
  elif [[ "${ioda_file}" == *atms* || "${ioda_file}" == *cris* ]]; then
    echo " ${ioda_file} ioda file detected: temporarily skipping offline domain check"
  else
    export pgm="offline_domain_check.py"
    ./offline_domain_check.py -o "${ioda_file}" -g "${grid_file}" -s 0.005
    #export err=$?; err_chk
    base_name=$(basename "$ioda_file" .nc)
    mv  "${base_name}_dc.nc" "${base_name}.nc"
    export pgm="offline_ioda_patch.py"
    if [[ "${ioda_file}" == *adpupa* ]]; then
      ./offline_ioda_patch.py -o "${ioda_file}" --patch-timeoffset >> $pgmout
    else
      ./offline_ioda_patch.py -o "${ioda_file}" >> $pgmout
    fi
    #export err=$?; err_chk
    base_name=$(basename "$ioda_file" .nc)
    mv  "${base_name}_llp.nc" "${base_name}.nc"
  fi
done

# vadwnd thinning & superobbing
export pgm="offline_vad_thinning.py"
./offline_vad_thinning.py -i ioda_vadwnd.nc -o ioda_vadwnd_thinned.nc >> $pgmout
#export err=$?; err_chk
mv ioda_vadwnd_thinned.nc ioda_vadwnd.nc

# Cast metadata to the type expected by OSDF
for ioda_file in ioda*.nc; do
  ./prep_ioda_cast.sh -i ${ioda_file}
done


## offline duplicate tagger (cycle-to-cycle duplicates) (0=new; 1=duplicate)
#obs_types=(adpupa adpsfc aircar aircft msonet vadwnd sfcshp rassda proflr)
#for obs in "${obs_types[@]}"; do
#  tm01_ioda="${CYCLE_BASEDIR}/${YYYYMMDDHHm1}/ioda_bufr/ioda_${obs}.nc"
#  if [[ -f $tm01_ioda ]]; then
#    tm00_ioda="./ioda_${obs}.nc"
#    tm00_ioda_out="ioda_${obs}_tagged.nc"
#    export pgm="offline_duplicate_tagger.py"
#    python offline_duplicate_tagger.py tag $tm00_ioda -p $tm01_ioda -o $tm00_ioda_out >> $pgmout
#    #export err=$?; err_chk
#    mv $tm00_ioda_out $tm00_ioda
#  fi
#done
#
#-----------------------------------------------------------------------
#
# Move ioda files to COMOUT
#
#-----------------------------------------------------------------------
#
#cp ioda_*.nc $COMOUT/.
#
#-----------------------------------------------------------------------
#
# Create empty file to note completion of task. This informs the next
# ioda_bufr task in the subsequent cycle that it may run. This is
# necessary for cycle-to-cycle duplicate tagging since each ioda_bufr
# task now depends on the completion of the previous.
#
#-----------------------------------------------------------------------
#
#touch "${ioda_bufr_nwges_dir}"/ioda_bufr_complete
#
#-----------------------------------------------------------------------
#
# Print message indicating successful completion of script.
#
#-----------------------------------------------------------------------
#
echo "PREPBUFR PROCESS completed successfully!!!"
