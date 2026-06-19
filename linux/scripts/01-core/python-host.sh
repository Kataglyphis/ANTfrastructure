#!/usr/bin/env bash
# python-host.sh - shared host Python environment setup for media build scripts.
#
# Sources this after common.sh / cross-python.sh are loaded.
# Provides:
#   setup_host_python_environment    - export HOST_PYTHON_BIN, PYTHON_EXECUTABLE,
#                                     Python_EXECUTABLE, Python3_EXECUTABLE
#   setup_host_python_with_major_minor - same + export PYTHON_MAJOR_MINOR

[ -n "${_PYTHON_HOST_SH_LOADED:-}" ] && return 0
_PYTHON_HOST_SH_LOADED=1

setup_host_python_environment() {
  HOST_PYTHON_BIN="$(host_python_bin)"
  export HOST_PYTHON_BIN
  export PYTHON_EXECUTABLE="${HOST_PYTHON_BIN}" \
         Python_EXECUTABLE="${HOST_PYTHON_BIN}" \
         Python3_EXECUTABLE="${HOST_PYTHON_BIN}"
}

setup_host_python_with_major_minor() {
  setup_host_python_environment
  if [ -z "${PYTHON_MAJOR_MINOR:-}" ]; then
    PYTHON_MAJOR_MINOR="$(host_python_major_minor 2>/dev/null || true)"
    export PYTHON_MAJOR_MINOR
  fi
}
