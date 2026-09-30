#!/usr/bin/env bash
# 3.14 and 3.14t are two uv requests (CON40); see docs/python-ci.md#free-threaded-and-gil-legs-in-one-container
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
UV_SH="${TESTS_DIR}/../01-core/python_uv.sh"

_fns=""
for _f in uv_python_request uv_ensure_python_available uv_venv_create; do
  _src="$(t_fn_src "${UV_SH}" "${_f}")" || exit 1
  _fns+="${_src}"$'\n'
done

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/bin"
# A PATH holding the GIL interpreter only, as the image does, and a uv that records its argv.
printf '#!/bin/sh\nexit 0\n' > "${_work}/bin/python3.14"
printf '#!/bin/sh\necho "uv $*" >> "%s/calls"\n' "${_work}" > "${_work}/bin/uv"
chmod +x "${_work}/bin/python3.14" "${_work}/bin/uv"

# _run <snippet>: the helpers in a clean shell, logging and the uv installer stubbed; prints uv's calls.
_run() {
  : > "${_work}/calls"
  HOME="${_work}/home" PATH="${_work}/bin:/usr/bin:/bin" bash -c '
    info() { :; }; warn() { :; }; uv_ensure_installed() { :; }
    '"${_fns}"'
    '"$1" >/dev/null 2>&1
  cat "${_work}/calls"
}

t_case "a bare version asks uv for the GIL build; a free-threaded or explicit request passes unchanged"
t_assert_eq "3.14+gil" "$(bash -c "${_fns}"' uv_python_request 3.14')"
t_assert_eq "3.14.4+gil" "$(bash -c "${_fns}"' uv_python_request 3.14.4')"
t_assert_eq "3.14t" "$(bash -c "${_fns}"' uv_python_request 3.14t')"
t_assert_eq "/usr/bin/python3" "$(bash -c "${_fns}"' uv_python_request /usr/bin/python3')"
t_assert_eq "" "$(bash -c "${_fns}"' uv_python_request ""')"

t_case "uv_venv_create 3.14 hands uv the GIL request, so a cached 3.14t cannot answer it"
t_assert_contains "$(_run 'uv_venv_create "'"${_work}"'/v" 3.14')" "uv venv --seed ${_work}/v --python=3.14+gil"

t_case "uv_venv_create 3.14t keeps the t, and python3.14 does not count as having it"
_calls="$(_run 'uv_venv_create "'"${_work}"'/v" 3.14t')"
t_assert_contains "${_calls}" "uv python install 3.14t" "the free-threaded interpreter must be installed"
t_assert_contains "${_calls}" "--python=3.14t"

t_case "a present GIL interpreter needs no install"
t_assert_eq "" "$(_run 'uv_ensure_python_available 3.14')"

t_case "an empty version leaves the choice to uv (UV_PYTHON)"
t_assert_eq "uv venv --seed ${_work}/v --clear" "$(_run 'uv_venv_create "'"${_work}"'/v" ""')"

t_summary
