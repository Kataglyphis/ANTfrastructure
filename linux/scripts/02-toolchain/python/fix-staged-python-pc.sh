#!/usr/bin/env bash
set -euo pipefail
# fix-staged-python-pc.sh — can be sourced (provides fix_python_pc_file) or executed directly.

fix_python_pc_file() {
  local pc_file="$1"
  [ -f "${pc_file}" ] || return 0

  sed -i \
    -e 's|^prefix=/usr/local$|prefix=${pcfiledir}/../..|' \
    -e 's|^libdir=\${exec_prefix}/lib$|libdir=${prefix}/lib|' \
    "${pc_file}"
}

# When executed directly (not sourced), scan the python-cross tree and fix pc files.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  CROSS_ROOT="${1:-/opt/python-cross}"
  for python_cross_root in "${CROSS_ROOT}"/*; do
    [ -d "${python_cross_root}/usr/local/lib/pkgconfig" ] || continue
    pc_dir="${python_cross_root}/usr/local/lib/pkgconfig"
    for pc in "${pc_dir}"/python-*.pc; do
      [ -f "${pc}" ] || continue
      fix_python_pc_file "${pc}"
      echo "Fixed ${pc}"
    done
  done
fi
