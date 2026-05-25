#!/bin/bash
# Convert GSI conventional diagnostic files for one cycle to JEDI jdiag files.
#
# Usage:
#   ./run_convert_gsi_diag_to_gdiag.sh YYYYMMDDHH /path/to/gsi/diag/directory
#
# The diagnostic directory must contain the analysis GSI diag files:
#   diag_conv_t_anl*
#   diag_conv_q_anl*
#   diag_conv_ps_anl*
#   diag_conv_uv_anl*
#
# Converted jdiag*.nc files are written back to the same directory.
# cltthinkdeb 
 script_dir=/u/ting.lei/dr-3kmNA-parallel/RRFS_analysis_PARALLEL/scripts

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 YYYYMMDDHH /path/to/gsi/diag/directory" >&2
  exit 2
fi

analysis_time="$1"
diag_dir="$2"

if [[ ! "${analysis_time}" =~ ^[0-9]{10}$ ]]; then
  echo "Error: analysis time must be in YYYYMMDDHH format: ${analysis_time}" >&2
  exit 2
fi

if [[ ! -d "${diag_dir}" ]]; then
  echo "Error: diagnostic directory does not exist: ${diag_dir}" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
gdiags=("${diag_dir}"/diag_conv_t_anl*)
gdiags+=("${diag_dir}"/diag_conv_q_anl*)
gdiags+=("${diag_dir}"/diag_conv_ps_anl*)
gdiags+=("${diag_dir}"/diag_conv_uv_anl*)
shopt -u nullglob

if [[ ${#gdiags[@]} -eq 0 ]]; then
  echo "Error: no GSI analysis diag files found in ${diag_dir}" >&2
  exit 1
fi

echo "Converting GSI diag files to JEDI jdiag for ${analysis_time}"
echo "Input/output directory: ${diag_dir}"

pushd "${diag_dir}" >/dev/null
python "${script_dir}/gdiag_to_jdiag.py" "${analysis_time}" "${gdiags[@]}"
popd >/dev/null

echo "Converted ${#gdiags[@]} GSI diag files. Output written to ${diag_dir}/jdiag*.nc"
