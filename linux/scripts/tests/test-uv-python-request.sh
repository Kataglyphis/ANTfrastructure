#!/usr/bin/env bash
# 3.14 and 3.14t are two uv requests (CON40); see docs/python-ci.md#free-threaded-and-gil-legs-in-one-container
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
UV_SH="${TESTS_DIR}/../01-core/python_uv.sh"

_fns=""
for _f in uv_python_request uv_image_ships_python uv_ensure_python_available uv_venv_create; do
  _src="$(t_fn_src "${UV_SH}" "${_f}")" || exit 1
  _fns+="${_src}"$'\n'
done

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/bin" "${_work}/ftbin"
# A PATH holding the GIL interpreter only, as the image does, and a uv that records its argv and UV_PYTHON_DOWNLOADS.
printf '#!/bin/sh\nexit 0\n' > "${_work}/bin/python3.14"
printf '#!/bin/sh\nexit 0\n' > "${_work}/ftbin/python3.14t"
printf '#!/bin/sh\necho "uv $*" >> "%s/calls"\necho "uv $* [downloads=${UV_PYTHON_DOWNLOADS:-unset}]" >> "%s/env"\n' "${_work}" "${_work}" > "${_work}/bin/uv"
chmod +x "${_work}/bin/python3.14" "${_work}/ftbin/python3.14t" "${_work}/bin/uv"

# _run <snippet> [VAR=value...]: the helpers in a clean shell, no image ENV unless given, logging and the uv installer stubbed; prints uv's calls.
_run() {
  local snippet="$1"; shift
  : > "${_work}/calls"; : > "${_work}/env"
  env -u PYTHON_CROSS_ACTIVE_ROOT -u PYTHON_MAJOR_MINOR -u UV_PYTHON_DOWNLOADS \
    HOME="${_work}/home" PATH="${_work}/bin:/usr/bin:/bin" "$@" bash -c '
    info() { :; }; warn() { :; }; uv_ensure_installed() { :; }
    '"${_fns}"'
    '"${snippet}" >/dev/null 2>&1
  echo "rc=$?"
  cat "${_work}/calls"
}
# The shipped image's ENV (Dockerfile.package).
_IMG=(PYTHON_CROSS_ACTIVE_ROOT=/opt/python-target PYTHON_MAJOR_MINOR=3.14)

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
t_assert_eq "rc=0" "$(_run 'uv_ensure_python_available 3.14')"

t_case "an empty version leaves the choice to uv (UV_PYTHON)"
t_assert_eq "rc=0"$'\n'"uv venv --seed ${_work}/v --clear" "$(_run 'uv_venv_create "'"${_work}"'/v" ""')"

t_case "in the image its 3.14t is found, never downloaded: uv venv runs with UV_PYTHON_DOWNLOADS=never (CON66)"
_calls="$(_run 'uv_venv_create "'"${_work}"'/v" 3.14t' "${_IMG[@]}" PATH="${_work}/bin:${_work}/ftbin:/usr/bin:/bin")"
t_assert_contains "${_calls}" "rc=0"
t_assert_eq 0 "$(printf '%s\n' "${_calls}" | grep -c -F "uv python install")" "the image's interpreter needs no install"
t_assert_contains "$(cat "${_work}/env")" "uv venv --seed ${_work}/v --python=3.14t --clear [downloads=never]"

t_case "in the image a missing 3.14t fails its venv instead of downloading one"
_calls="$(_run 'uv_venv_create "'"${_work}"'/v" 3.14t' "${_IMG[@]}")"
t_assert_contains "${_calls}" "rc=1"
t_assert_eq 0 "$(printf '%s\n' "${_calls}" | grep -c -F "uv python install")" "an image that lost its interpreter must not be patched by a download"
t_assert_eq 0 "$(printf '%s\n' "${_calls}" | grep -c -F "uv venv")" "no venv from some other interpreter"

t_case "in the image the GIL 3.14 is its own too; a version it does not ship may still download"
_run 'uv_venv_create "'"${_work}"'/v" 3.14' "${_IMG[@]}" >/dev/null
t_assert_contains "$(cat "${_work}/env")" "--python=3.14+gil --clear [downloads=never]"
_calls="$(_run 'uv_venv_create "'"${_work}"'/v" 3.13' "${_IMG[@]}")"
t_assert_contains "${_calls}" "uv python install 3.13"
t_assert_contains "$(cat "${_work}/env")" "--python=3.13+gil --clear [downloads=unset]"

t_case "a caller's own UV_PYTHON_DOWNLOADS wins; outside the image nothing changes"
_run 'uv_venv_create "'"${_work}"'/v" 3.14t' "${_IMG[@]}" PATH="${_work}/bin:${_work}/ftbin:/usr/bin:/bin" UV_PYTHON_DOWNLOADS=automatic >/dev/null
t_assert_contains "$(cat "${_work}/env")" "--python=3.14t --clear [downloads=automatic]"
_run 'uv_venv_create "'"${_work}"'/v" 3.14t' PATH="${_work}/bin:${_work}/ftbin:/usr/bin:/bin" >/dev/null
t_assert_contains "$(cat "${_work}/env")" "--python=3.14t --clear [downloads=unset]"

t_summary
