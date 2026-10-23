#!/usr/bin/env bash
# Prefix-only fixtures cover candidate ordering, framework initialization and failures without invoking package or build commands.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BASE_SCRIPT="${1:-${TESTS_DIR}/../01-core/base-image.sh}"
SETUP_SCRIPT="${2:-${TESTS_DIR}/../02-toolchain/setup-dependencies.sh}"
BOOTSTRAP="${3:-${TESTS_DIR}/../01-core/module-bootstrap.sh}"
DOCKER_ROOT="${4:-${TESTS_DIR}/../../..}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cat > "${WORK}/worker.sh" <<'BASH'
set -euo pipefail
function [ {
  local arguments=("$@")
  if [[ "${1:-}" = -f && "${2:-}" = /opt/scripts/core/* ]]; then
    arguments[1]="${BOOTSTRAP_OPT}/${2##*/}"
  fi
  builtin [ "${arguments[@]}"
}
function source {
  local path="$1"; shift
  if [[ "$path" = /opt/scripts/core/* ]]; then path="${BOOTSTRAP_OPT}/${path##*/}"; fi
  builtin source "$path" "$@"
}
run_prefix() {
  source "$1"
  printf '%s\n' BOOTSTRAPPED
}
if [[ "${2:-direct}" != direct ]]; then unset -f source; fi
case "${2:-direct}" in
  direct) run_prefix "$1" ;;
  if) if run_prefix "$1"; then :; else exit $?; fi ;;
  not) if ! run_prefix "$1"; then exit 1; fi ;;
esac
BASH

_bootstrap_fixture_module() {
  local path="$1" label="$2" source_status="${3:-0}" framework_status="${4:-0}"
  mkdir -p "${path%/*}"
  cat > "${path}" <<BASH
printf '%s\\n' 'source ${label}' >> "\${BOOTSTRAP_LOG}"
source_modules_framework() {
  printf 'framework %s\\n' "\$1" >> "\${BOOTSTRAP_LOG}"
  return ${framework_status}
}
return ${source_status}
BASH
}

_bootstrap_prepare_scenario() {
  local root="$1" directory="$2" mode="$3" context="$4"
  local -n _bps_selected="$5" _bps_expected="$6"
  case "${mode}" in
    container)
      _bootstrap_fixture_module "${root}/opt/modules.sh" container
      _bootstrap_fixture_module "${directory}/modules.sh" local
      _bps_selected=container ;;
    local)
      _bootstrap_fixture_module "${directory}/modules.sh" local
      _bps_selected=local ;;
    relative)
      _bootstrap_fixture_module "${root}/01-core/modules.sh" relative
      rm "${directory}/module-bootstrap.sh"
      _bps_selected=relative ;;
    missing) _bps_expected=1 ;;
    source-failure)
      if [ "${context}" = direct ]; then
        _bootstrap_fixture_module "${root}/opt/modules.sh" broken 17
        _bootstrap_fixture_module "${directory}/modules.sh" local
      else
        _bootstrap_fixture_module "${directory}/modules.sh" broken 17
      fi
      _bps_selected=broken; _bps_expected=17 ;;
    framework-failure)
      _bootstrap_fixture_module "${directory}/modules.sh" broken 0 23
      _bps_selected=broken; _bps_expected=23 ;;
  esac
  if [ "${context}" != direct ] && [[ "${mode}" = *-failure ]]; then _bps_expected=0; fi
}

_bootstrap_case() {
  local kind="$1" mode="$2" context="${3:-direct}" selected='' expected=0 directory root prefix actual rc=0
  root="$(mktemp -d "${WORK}/case.XXXXXX")"
  directory="${root}/${kind}"
  mkdir -p "${directory}" "${root}/01-core" "${root}/opt"
  install -m 0644 "${BOOTSTRAP}" "${directory}/module-bootstrap.sh"
  install -m 0644 "${BOOTSTRAP}" "${root}/01-core/module-bootstrap.sh"
  prefix="${directory}/entry.sh"
  if [ "${kind}" = base ]; then
    awk '/^source_module / { exit } { print }' "${BASE_SCRIPT}" > "${prefix}"
  else
    awk '/^source_module / { exit } { print }' "${SETUP_SCRIPT}" > "${prefix}"
  fi
  _bootstrap_prepare_scenario "${root}" "${directory}" "${mode}" "${context}" selected expected
  actual="$(BOOTSTRAP_LOG="${root}/events" BOOTSTRAP_OPT="${root}/opt" bash "${WORK}/worker.sh" "${prefix}" "${context}" 2> "${root}/err")" || rc=$?
  t_assert_eq "${expected}" "${rc}" "${kind}/${mode} exit policy"
  if [ "${mode}" = missing ]; then
    t_assert_eq 'Error: modules.sh not found' "$(cat "${root}/err")"
    t_assert_fails test -e "${root}/events"
  else
    t_assert_eq "source ${selected}" "$(head -n 1 "${root}/events")" 'the first existing module wins'
    if [ "${mode}" = source-failure ] && [ "${context}" = direct ]; then
      t_assert_eq 1 "$(wc -l < "${root}/events")" 'failed source cannot initialize or try another candidate'
    else
      t_assert_eq "framework ${directory}" "$(tail -n 1 "${root}/events")" 'the selected framework receives the caller directory once'
      t_assert_eq 2 "$(wc -l < "${root}/events")"
    fi
  fi
  if [ "${expected}" = 0 ]; then t_assert_eq BOOTSTRAPPED "${actual}"; else t_assert_eq '' "${actual}"; fi
}

for kind in base setup; do
  for mode in container local missing source-failure framework-failure; do
    t_case "${kind} module bootstrap ${mode}"
    _bootstrap_case "${kind}" "${mode}"
  done
done
t_case 'setup retains its extra repository-relative module candidate'
_bootstrap_case setup relative
for context in if not; do
  for kind in base setup; do
    for mode in source-failure framework-failure; do
      t_case "${kind} ${mode} under an outer ${context} condition retains the original errexit context"
      _bootstrap_case "${kind}" "${mode}" "${context}"
    done
  done
done

t_case 'per-file build inputs and the SDK COPY retain the bootstrap companion'
t_assert_ok python3 - "${DOCKER_ROOT}" <<'PYTHON'
from pathlib import Path
import sys
root = Path(sys.argv[1])
checks = [('base', '01-core/base-image.sh', 6), ('toolchain', '02-toolchain/setup-dependencies.sh', 2)]
for name, entry, expected in checks:
    text = (root / 'linux' / ('Dockerfile.' + name)).read_text()
    instructions = text.replace(chr(92) + "\n", " ").splitlines()
    runs = [line for line in instructions if line.startswith('RUN ') and 'source=linux/scripts/' + entry + ',' in line]
    assert len(runs) == expected, (name, len(runs))
    for run in runs:
        assert 'source=linux/scripts/01-core/module-bootstrap.sh,' in run, name
sdk = (root / 'linux/Dockerfile.sdk').read_text().replace(chr(92) + "\n", " ").splitlines()
assert any(line.startswith('COPY ') and 'linux/scripts/01-core/module-bootstrap.sh' in line and '/opt/scripts/core/' in line for line in sdk)
PYTHON

t_summary
