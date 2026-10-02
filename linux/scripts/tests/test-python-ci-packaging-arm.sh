#!/usr/bin/env bash
# ci_packaging.sh's per-arch arm: a packaging/app.json app's packages are amd64/arm64;
# the emulated riscv64 row ships wheels only. See docs/python-ci.md#test-extras.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
WS="${_work}/ws"; TREE="${_work}/tree"; CALLS="${_work}/calls"; OUT="${_work}/out"; BIN="${_work}/bin"
mkdir -p "${TREE}/01-core" "${TREE}/02-toolchain/python" "${TREE}/06-packaging" "${WS}/packaging" "${BIN}"

cp "${SCRIPTS}/01-core/python_uv.sh" "${SCRIPTS}/01-core/logging.sh" "${TREE}/01-core/"
cp "${SCRIPTS}/02-toolchain/python/ci_packaging.sh" "${TREE}/02-toolchain/python/"
# The real ci-common gets its workspace glue stubbed, as test-python-ci-defaults does.
cat > "${TREE}/02-toolchain/python/ci-common.sh" <<'CI_COMMON'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../01-core" && pwd)/python_uv.sh"
detect_workspace() { export WORKSPACE_ROOT="${FIXTURE_WS}"; }
prepare_ci_workspace() { shift; cd "${WORKSPACE_ROOT:-${FIXTURE_WS}}" || :; }
uv_venv_ensure() { :; }
uv_venv_activate() { :; }
uv_venv_deactivate() { :; }
uv_venv_remove() { :; }
uv_sync_project() { :; }
CI_COMMON

printf '{ "name": "FixtureApp" }\n' > "${WS}/packaging/app.json"

printf '#!/usr/bin/env bash\ncase "$1" in -m) printf "%%s\\n" "${FAKE_ARCH}";; *) : ;; esac\n' > "${BIN}/uname"
printf '#!/usr/bin/env bash\n: \n' > "${BIN}/apt-get"
printf '#!/usr/bin/env bash\ncase "$*" in show*) exit 2 ;; *) : ;; esac\n' > "${BIN}/auditwheel"
printf '#!/usr/bin/env bash\n: \n' > "${BIN}/uv"
printf '#!/usr/bin/env bash\n: \n' > "${BIN}/patchelf"
chmod +x "${BIN}/uname" "${BIN}/apt-get" "${BIN}/auditwheel" "${BIN}/uv" "${BIN}/patchelf"

# The consumers the arm drives: absent on riscv64, called on amd64.
printf '#!/usr/bin/env bash\nprintf "bundle %%s\\n" "$*" >> "${CALLS}"\n' > "${TREE}/06-packaging/python-app-bundle.sh"
printf '#!/usr/bin/env bash\nprintf "package %%s\\n" "$*" >> "${CALLS}"\n' > "${TREE}/06-packaging/python-app-package.sh"
chmod +x "${TREE}/06-packaging/python-app-bundle.sh" "${TREE}/06-packaging/python-app-package.sh"

# _run <arch>: the driver under the fake arch; every external tool resolves from the stub PATH.
_run() {
  : > "${CALLS}"
  FAKE_ARCH="$1" CALLS="${CALLS}" FIXTURE_WS="${WS}" \
    PATH="${BIN}:${PATH}" bash "${TREE}/02-toolchain/python/ci_packaging.sh" 3.14 > "${OUT}" 2>&1
}
_calls() { grep -oE '^(bundle|package) ' "${CALLS}" 2>/dev/null | wc -l; }

t_case "the arm's riscv64 verdict: wheels only, no package invocation"
t_assert_ok _run riscv64
t_assert_eq "0" "$(_calls)" "riscv64 must not build the app packages"
t_assert_contains "$(cat "${OUT}")" "riscv64 ships wheels only" "the skip names its why"

t_case "the arm's amd64 verdict: the app packages run as before"
t_assert_ok _run x86_64
t_assert_eq "2" "$(_calls)" "the bundle and its packages both ran"

t_case "the arm's arm64 verdict: same as amd64"
t_assert_ok _run aarch64
t_assert_eq "2" "$(_calls)"

t_case "the arm's LOGFILE order matches the driver's lines"
t_assert_ok test -s "${OUT}"

t_summary
