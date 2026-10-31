#!/usr/bin/env bash
# Copied Python CI drivers carry the companions required by their uv module.
python_ci_fixture() {
  t_python_ci_fixture "$1" "$2" 01-core/python-probe.sh 01-core/verified-script-install.sh "${@:3}"
}

# ci_tests.sh with the companions it executes; extra relative paths follow.
python_ci_tests_fixture() {
  python_ci_fixture "$1" "$2" 01-core/versions.env 02-toolchain/python/ci_tests.sh \
    02-toolchain/python/free-threaded-wheel.py 02-toolchain/python/verify-test-reports.py "${@:3}"
}

# Venv lifecycle no-ops for a driver whose suite records only uv effects.
python_ci_venv_noops() {
  printf '%s\n' 'uv_venv_activate() { :; }; uv_venv_deactivate() { :; }; uv_venv_remove() { :; }' \
    >> "${TREE}/02-toolchain/python/ci-common.sh"
}
