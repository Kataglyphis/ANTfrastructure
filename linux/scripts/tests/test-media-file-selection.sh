#!/usr/bin/env bash
# Caller-side sourcing keeps BASH_SOURCE, positional arguments and failures intact.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${1:-${TESTS_DIR}/../03-media/core/common.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

CORE="${WORK}/linux/scripts/03-media/core"
COMPONENT="${WORK}/linux/scripts/03-media/build/opencv"
REPO_CORE="${WORK}/linux/scripts/01-core"
INSTALLED_CORE="${WORK}/opt/scripts/core"
INSTALLED_MEDIA="${WORK}/opt/scripts/03-media/core"
mkdir -p "${CORE}" "${COMPONENT}" "${REPO_CORE}" "${INSTALLED_CORE}" "${INSTALLED_MEDIA}"
sed -e "s|/opt/scripts/core/|${INSTALLED_CORE}/|g" \
    -e "s|/opt/scripts/03-media/core/|${INSTALLED_MEDIA}/|g" \
    "${SUBJECT}" > "${CORE}/common.sh"

cat > "${COMPONENT}/driver.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "${CORE_PATH}"
if [ "${TEST_ALIAS:-0}" = 1 ]; then
  shopt -s expand_aliases
  _probe_file() {
    local -a _args=("$@")
    local _path="${_args[-2]}"
    printf '%s\n' "$*" >> "${ALIAS_TRACE}"
    builtin test -f "${_path}"
  }
  alias '['='_probe_file "$@"'
  eval "$(sed -n '/^_media_candidate_exists() {/,/^}/p' "${CORE_PATH}")"
fi
media_install_deps_init "${COMPONENT_DIR}"
printf 'RESULT:%s|%s|%s|%s|%s|%s|%s\n' \
  "${media_test_SOURCE:-<none>}" "${media_test_ARCH:-<none>}" \
  "${media_test_FRAME:-<none>}" "${media_test_ARGC:-<none>}" "${media_test_ARG:-<none>}" \
  "${media_test_SLOTS:-<none>}" "${media_test_FLAG_SLOTS:-<none>}"
BASH

_clear_candidates() {
  rm -f "${INSTALLED_CORE}/install-deps-preamble.sh" \
    "${REPO_CORE}/install-deps-preamble.sh" \
    "${INSTALLED_MEDIA}/arch-flags-amd64.env" \
    "${CORE}/arch-flags-amd64.env"
  rm -f "${WORK}/output"
}

_write_source() {
  local path="$1" label="$2" rc="${3:-0}"
  cat > "${path}" <<BASH
media_test_SOURCE=${label}
media_test_FRAME="\${BASH_SOURCE[0]}|\${BASH_SOURCE[1]:-}"
media_test_ARGC="\$#"
media_test_ARG="\${1:-<unset>}"
media_test_SLOTS="\${candidate:-<unset>}|\${_dep_env:-<unset>}"
return ${rc}
BASH
}

_write_flags() {
  local path="$1" label="$2" rc="${3:-0}"
  cat > "${path}" <<BASH
media_test_ARCH=${label}
media_test_FLAG_SLOTS="\${candidate:-<unset>}|\${_dep_env:-<unset>}"
return ${rc}
BASH
}

_run() {
  local rc=0
  CORE_PATH="${CORE}/common.sh" COMPONENT_DIR="${COMPONENT}" \
    ALIAS_TRACE="${WORK}/alias.trace" \
    bash "${COMPONENT}/driver.sh" marker > "${WORK}/output" 2>&1 || rc=$?
  printf '%s' "${rc}"
}

_clear_candidates
_write_source "${INSTALLED_CORE}/install-deps-preamble.sh" installed
_write_source "${REPO_CORE}/install-deps-preamble.sh" repo
_write_flags "${INSTALLED_MEDIA}/arch-flags-amd64.env" installed
_write_flags "${CORE}/arch-flags-amd64.env" repo
t_case 'installed media helpers retain priority and source in the caller frame'
t_assert_eq 0 "$(_run)"
t_assert_contains "$(cat "${WORK}/output")" "RESULT:installed|installed|${INSTALLED_CORE}/install-deps-preamble.sh|${CORE}/common.sh|1|${COMPONENT}|<unset>|${INSTALLED_CORE}/install-deps-preamble.sh|${INSTALLED_MEDIA}/arch-flags-amd64.env|${INSTALLED_CORE}/install-deps-preamble.sh"

_clear_candidates
_write_source "${REPO_CORE}/install-deps-preamble.sh" repo
_write_flags "${CORE}/arch-flags-amd64.env" repo
t_case 'repository helpers remain the fallback for both media loaders'
t_assert_eq 0 "$(_run)"
t_assert_contains "$(cat "${WORK}/output")" "RESULT:repo|repo|${COMPONENT}/../../../01-core/install-deps-preamble.sh|${CORE}/common.sh|1|${COMPONENT}|<unset>|${COMPONENT}/../../../01-core/install-deps-preamble.sh|${CORE}/arch-flags-amd64.env|${COMPONENT}/../../../01-core/install-deps-preamble.sh"

_clear_candidates
t_case 'missing optional candidates leave the media defaults untouched'
t_assert_eq 0 "$(_run)"
t_assert_contains "$(cat "${WORK}/output")" "RESULT:<none>|<none>|<none>|<none>|<none>|<none>|<none>"

_clear_candidates
_write_flags "${CORE}/arch-flags-amd64.env" repo
t_case 'a sourced arch file still sees the last preamble candidate when none exists'
t_assert_eq 0 "$(_run)"
t_assert_contains "$(cat "${WORK}/output")" "RESULT:<none>|repo|<none>|<none>|<none>|<none>|${CORE}/arch-flags-amd64.env|${COMPONENT}/../../../01-core/install-deps-preamble.sh"

_clear_candidates
_write_source "${INSTALLED_CORE}/install-deps-preamble.sh" installed
_write_flags "${INSTALLED_MEDIA}/arch-flags-amd64.env" installed
t_case 'the file-test alias receives the original caller arguments'
CORE_PATH="${CORE}/common.sh" COMPONENT_DIR="${COMPONENT}" ALIAS_TRACE="${WORK}/alias.trace" \
  TEST_ALIAS=1 bash "${COMPONENT}/driver.sh" marker > "${WORK}/output" 2>&1
t_assert_contains "$(cat "${WORK}/alias.trace")" "${COMPONENT} -f ${INSTALLED_CORE}/install-deps-preamble.sh ]"
t_assert_contains "$(cat "${WORK}/alias.trace")" "-f ${INSTALLED_MEDIA}/arch-flags-amd64.env ]"

_clear_candidates
_write_source "${INSTALLED_CORE}/install-deps-preamble.sh" installed 17
_write_source "${REPO_CORE}/install-deps-preamble.sh" repo
t_case 'a selected preamble failure stays fatal and never falls through'
t_assert_eq 1 "$(_run)"
t_assert_grep "${WORK}/output" "FATAL: cannot load ${INSTALLED_CORE}/install-deps-preamble.sh"
t_assert_no_grep "${WORK}/output" 'RESULT:|media_test_SOURCE=repo'

_clear_candidates
_write_flags "${INSTALLED_MEDIA}/arch-flags-amd64.env" installed 17
_write_flags "${CORE}/arch-flags-amd64.env" repo
t_case 'a selected architecture file failure keeps its raw status'
t_assert_eq 17 "$(_run)"
t_assert_no_grep "${WORK}/output" 'media_test_ARCH=repo|RESULT:'

t_summary
