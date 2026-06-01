#!/bin/bash -l

WORKDIR=/u/ting.lei/dr-3kmNA-parallel/RRFS_analysis_PARALLEL
LOCKDIR=${WORKDIR}/.run_hyb.lock
LOG=${WORKDIR}/driver_auto.log
HYBRIDVAR_BASEDIR=${HybridVar_BASERUNDIR:-/lfs/h2/emc/stmp/${USER}/HybridVar_PARALLEL}
HYBRIDVAR_HISTORY=${HYBRIDVAR_BASEDIR}/.enspath_cycle_history.txt

cd "${WORKDIR}" || exit 10

show_log_locations() {
  local latest_monitor
  local latest_summary

  echo "$(date): Log locations:"
  echo "  auto-wrapper log: ${LOG}"
  echo "  HybridVar history: ${HYBRIDVAR_HISTORY}"
  echo "  HybridVar monitor directory: ${HYBRIDVAR_BASEDIR}"

  latest_monitor=$(ls -1t "${HYBRIDVAR_BASEDIR}"/monitor_enspath_*.status 2>/dev/null | head -1 || true)
  if [[ -n "${latest_monitor}" ]]; then
    echo "  most recent HybridVar monitor log: ${latest_monitor}"
    latest_summary=$(grep '^CYCLE_SUMMARY_STATUS=' "${latest_monitor}" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [[ -n "${latest_summary}" ]]; then
      echo "  most recent launched-cycle summary: ${latest_summary}"
      echo "  launched-cycle PBS logs directory: $(dirname "${latest_summary}")"
    fi
  fi
}

if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  echo "$(date): Another DRIVER_analysis_auto.sh is already running. Exit."
  show_log_locations
  exit 0
fi

(
  trap 'rm -rf "${LOCKDIR}"' EXIT
  set -o pipefail

  echo "$(date): Starting DRIVER_analysis_auto.sh"
  show_log_locations
  ./DRIVER_analysis_auto.sh 2>&1 | tee -a "${LOG}"
  status=${PIPESTATUS[0]}
  echo "$(date): DRIVER_analysis_auto.sh finished with status ${status}"
  show_log_locations

) &

echo "$(date): Started DRIVER_analysis_auto.sh in background."
echo "  Detailed auto-wrapper output is also appended to: ${LOG}"
exit 0
