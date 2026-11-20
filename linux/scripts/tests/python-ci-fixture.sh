#!/usr/bin/env bash
# Copied Python CI drivers carry the companions required by their uv module.
python_ci_fixture() {
  t_python_ci_fixture "$1" "$2" 01-core/python-probe.sh 01-core/verified-script-install.sh \
    02-toolchain/python/ci-compiler-cache.sh "${@:3}"
}

# Cache-enabled driver fixtures share executable placeholders and resolver stubs.
python_ci_cache_fixture() {
  export FAKE_CACHE_LAUNCHER="${BIN}/cache-launcher" FIXTURE_CC="${BIN}/plain-cc" FIXTURE_CXX="${BIN}/plain-cxx"
  local cache_fixture_tool
  for cache_fixture_tool in "$FAKE_CACHE_LAUNCHER" "$FIXTURE_CC" "$FIXTURE_CXX"; do
    printf '#!/usr/bin/env bash\n:\n' > "$cache_fixture_tool" || return 1
    chmod +x "$cache_fixture_tool" || return 1
  done
  cat >> "${TREE}/02-toolchain/python/ci-common.sh" <<'CACHE_API'
compiler_cache_launcher_env() { :; }
compiler_cache_launcher() { printf '%s\n' "${FAKE_CACHE_LAUNCHER:?}"; }
CACHE_API
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
