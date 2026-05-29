#!/bin/bash -l

WORKDIR=/u/ting.lei/dr-3kmNA-parallel/RRFS_analysis_PARALLEL
LOCKDIR=${WORKDIR}/.run_hyb.lock
LOG=${WORKDIR}/driver_auto.log

cd "${WORKDIR}" || exit 10

if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  echo "$(date): Another DRIVER_analysis_auto.sh is already running. Exit."
  exit 0
fi

(
  trap 'rm -rf "${LOCKDIR}"' EXIT

  echo "$(date): Starting DRIVER_analysis_auto.sh"
  ./DRIVER_analysis_auto.sh >> "${LOG}" 2>&1
  status=$?
  echo "$(date): DRIVER_analysis_auto.sh finished with status ${status}"

) &

echo "$(date): Started DRIVER_analysis_auto.sh in background."
exit 0
