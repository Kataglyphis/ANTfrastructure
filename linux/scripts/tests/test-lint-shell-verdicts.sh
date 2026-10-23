#!/usr/bin/env bash
# A pinned fake shellcheck grades reporter flags and fatal/advisory status; no downloads or real shell analysis run.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${1:-${TESTS_DIR}/../lint-shell.sh}"
WORK="$(mktemp -d '/tmp/ant-shell verdict.XXXXXXXX')"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/tree/linux/scripts/01-core" "${WORK}/tree/src" "${WORK}/bin"
cp "${SUBJECT}" "${WORK}/tree/linux/scripts/lint-shell.sh"
cp "${TESTS_DIR}/../lib-ordered-jobs.sh" "${WORK}/tree/linux/scripts/"
for companion in lint-root.sh lint-tool-release.sh load-versions-env.sh tool-pins.env downloads.sh; do
  cp "${TESTS_DIR}/../01-core/${companion}" "${WORK}/tree/linux/scripts/01-core/"
done
pin="$(sed -n 's/^SHELLCHECK_VERSION=v\{0,1\}//p' "${TESTS_DIR}/../01-core/tool-pins.env")"
export FIXTURE_PIN="${pin}" FIXTURE_CALLS="${WORK}/calls"
cat > "${WORK}/bin/shellcheck" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = --version ]; then printf 'version: %s\n' "$FIXTURE_PIN"; exit 0; fi
printf '<%s>' "$@" >> "$FIXTURE_CALLS"; printf '\n' >> "$FIXTURE_CALLS"
case "$FIXTURE_MODE:$*" in
  error:'-S error '*) printf 'error diagnostic\n'; exit 7 ;;
  orphan:'--include=SC2215 -S warning '*) printf 'orphan diagnostic\n'; exit 8 ;;
  warning:'-S warning '*) printf 'warning diagnostic\n'; exit 9 ;;
esac
exit 0
STUB
chmod +x "${WORK}/bin/shellcheck"
printf '#!/bin/sh\ntrue\n' > "${WORK}/tree/src/bad file.sh"
for mode in error orphan warning clean; do
  t_case "${mode}: reporter command and final status"
  : > "${WORK}/calls"; status=0
  env FIXTURE_MODE="${mode}" PATH="${WORK}/bin:${PATH}" LINT_SHELL_JOBS=1 \
    bash "${WORK}/tree/linux/scripts/lint-shell.sh" --warning "${WORK}/tree/src/bad file.sh" > "${WORK}/output" 2>&1 || status=$?
  expected=0; case "${mode}" in error|orphan) expected=1 ;; esac
  t_assert_eq "${expected}" "${status}"
  output="$(cat "${WORK}/output")"
  case "${mode}" in
    error)
      t_assert_contains "${output}" 'shellcheck -S error found 1 file(s) with error-level findings:'
      t_assert_contains "${output}" '    error diagnostic'
      expected_args="<-S><error><${WORK}/tree/src/bad file.sh>"
      t_assert_eq 2 "$(grep -Fxc -- "${expected_args}" "${WORK}/calls")"
      t_assert_rc 1 grep -F -- '--include=SC2215' "${WORK}/calls" ;;
    orphan)
      t_assert_contains "${output}" 'SC2215 (flag used as a command name -- bad line break) in 1 file(s):'
      t_assert_contains "${output}" '    orphan diagnostic'
      expected_args="<--include=SC2215><-S><warning><${WORK}/tree/src/bad file.sh>"
      t_assert_eq 2 "$(grep -Fxc -- "${expected_args}" "${WORK}/calls")" ;;
    warning)
      t_assert_contains "${output}" '1 file(s) carry warning-level findings (non-fatal):'
      t_assert_contains "${output}" 'src/bad file.sh'
      t_assert_rc 0 grep -Fx -- "<-S><warning><${WORK}/tree/src/bad file.sh>" "${WORK}/calls" ;;
    clean) t_assert_contains "${output}" 'shellcheck -S warning also clean' ;;
  esac
done
t_summary
