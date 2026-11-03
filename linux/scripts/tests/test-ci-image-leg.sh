#!/usr/bin/env bash
# ci-image-leg.sh's refusals and uv binding, with stubbed interpreters and uv; not covered: a real image's interpreters or what the command does with them.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
LEG="${TESTS_DIR}/../ci-image-leg.sh"
BIN="${_work}/bin"
mkdir -p "${BIN}"
printf '#!/bin/sh\necho "uv $*" >> "%s/uv.log"\nmkdir -p "$3"\n' "${_work}" > "${BIN}/uv"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/python9.9"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/python9.9t"
chmod +x "${BIN}"/*
declare out rc

_leg() {
  out="$(PATH="${BIN}:${PATH}" PYTHON_CROSS_ACTIVE_ROOT=/fixture PYTHON_MAJOR_MINOR="${MM-9.9}" bash "${LEG}" "$@" 2>&1)"
  rc=$?
}

t_case "a leg outside the image refuses and names the interpreter"
MM="" _leg pinned "${_work}/v" true
t_assert_eq "2" "${rc}"
t_assert_contains "${out}" "runs in the family Linux image"
MM=8.8 _leg pinnedt "${_work}/v" true
t_assert_eq "2" "${rc}"
t_assert_contains "${out}" "ships python8.8t"

t_case "a bad leg, or no venv or command, prints the usage"
_leg other "${_work}/v" true
t_assert_eq "2" "${rc}"
t_assert_contains "${out}" "usage: ci-image-leg.sh"
_leg pinned "${_work}/v"
t_assert_eq "2" "${rc}"
_leg pinned "" true
t_assert_eq "2" "${rc}"

t_case "each leg builds its venv on its interpreter, and the command sees uv bound to it with downloads off"
_leg pinnedt "${_work}/ft" bash -c 'printf "%s|%s|%s\n" "${UV_PROJECT_ENVIRONMENT}" "${UV_PYTHON}" "${UV_PYTHON_DOWNLOADS}"'
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "${_work}/ft|${_work}/ft/bin/python|never"
t_assert_contains "$(cat "${_work}/uv.log")" "--python=9.9t"
_leg pinned "${_work}/gil" true
t_assert_eq "0" "${rc}"
t_assert_contains "$(tail -1 "${_work}/uv.log")" "--python=9.9+gil"

t_case "the command's status is the leg's"
_leg pinned "${_work}/gil" bash -c 'exit 7'
t_assert_eq "7" "${rc}"

t_summary
