#!/usr/bin/env bash
set -euo pipefail

# fix-staged-python-pc.sh
# Fix staged cross-compiled Python pkg-config files so they resolve into
# the per-architecture staging trees instead of the build host's /usr/local
# prefix. Without this rewrite, downstream Meson builds (gst-python, OpenCV)
# link against the host amd64 libpython instead of the target architecture's
# libpython.
#
# Usage:
#   fix-staged-python-pc.sh                     # scan /opt/python-cross
#   fix-staged-python-pc.sh /opt/python-cross   # explicit root

CROSS_ROOT="${1:-/opt/python-cross}"

fix_python_pc_file() {
  local pc_file="$1"
  [ -f "${pc_file}" ] || return 0

  sed -i \
    -e 's|^prefix=/usr/local$|prefix=${pcfiledir}/../..|' \
    -e 's|^exec_prefix=\${prefix}$|exec_prefix=${prefix}|' \
    -e 's|^libdir=\${exec_prefix}/lib$|libdir=${prefix}/lib|' \
    -e 's|^includedir=\${prefix}/include$|includedir=${prefix}/include|' \
    "${pc_file}"
}

for python_cross_root in "${CROSS_ROOT}"/*; do
  [ -d "${python_cross_root}/usr/local/lib/pkgconfig" ] || continue
  pc_dir="${python_cross_root}/usr/local/lib/pkgconfig"
  for pc in "${pc_dir}"/python-*.pc; do
    [ -f "${pc}" ] || continue
    fix_python_pc_file "${pc}"
    echo "Fixed ${pc}"
  done
done
