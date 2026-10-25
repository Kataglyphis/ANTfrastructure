#!/usr/bin/env bash
# A stubbed uvx keeps the refactor contract independent of network and Ruff cache state.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/git-fixture-env.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
PIN="$(sed -n 's/^RUFF_VERSION=//p' "${SCRIPTS_DIR}/01-core/tool-pins.env")"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${WORK}"' EXIT

new_root() {
  local root
  root="$(mktemp -d "${WORK}/repo.XXXXXXXX")" || return 1
  mkdir -p "${root}/linux/scripts/01-core" "${root}/bin" "${root}/app" || return 1
  cp "${SCRIPTS_DIR}/refactor-python.sh" "${root}/linux/scripts/" || return 1
  cp "${SCRIPTS_DIR}/01-core/load-versions-env.sh" "${SCRIPTS_DIR}/01-core/lint-root.sh" \
    "${root}/linux/scripts/01-core/" || return 1
  printf 'RUFF_VERSION=%s\n' "${PIN}" > "${root}/linux/scripts/01-core/tool-pins.env"
  printf 'logs/\n' > "${root}/.gitignore"
  printf 'bad_lint = bad_format\nunsafe_candidate = 1\n' > "${root}/app/one.py"
  printf 'bad_lint = bad_format\n' > "${root}/app/two.py"
  printf 'print("ok")\n' > "${root}/app/clean.py"
  { printf 'python3 - %s\n' "<<'PY'"
    printf 'print("from a shell heredoc")\nPY\n'
  } > "${root}/linux/scripts/probe.sh"
  cat > "${root}/bin/uvx" <<'UVX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALLS}"
case "$1" in ruff@*) ;; *) exit 90 ;; esac
shift
action="$1"; shift
fix=0 check=0 unsafe=0
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in --fix) fix=1 ;; --check) check=1 ;; --unsafe-fixes) unsafe=1 ;; esac
  shift
done
[ "$#" -gt 0 ] && shift
for file in "$@"; do
  case "$action" in
    check)
      if [ "$fix" -eq 1 ]; then
        sed -i 's/bad_lint/fixed_lint/g' "$file"
        [ "$unsafe" -eq 0 ] || sed -i 's/unsafe_candidate/unsafe_changed/g' "$file"
        if [ "${STUB_FAIL:-}" = after-fix ]; then echo 'forced Ruff failure'; exit 42; fi
      elif [ "${STUB_FAIL:-}" = check ]; then
        echo 'forced Ruff failure'; exit 43
      fi
      grep -q bad_lint "$file" && { echo 'lint drift'; exit 1; }
      ;;
    format)
      if [ "$check" -eq 1 ]; then
        grep -q bad_format "$file" && { echo 'format drift'; exit 1; }
      else
        sed -i 's/bad_format/fixed_format/g' "$file"
      fi
      ;;
    *) exit 91 ;;
  esac
done
exit 0
UVX
  chmod +x "${root}/bin/uvx" || return 1
  git -C "${root}" init -q || return 1
  t_git_commit "${root}" || return 1
  printf '%s\n' "${root}"
}

run_refactor() {
  local root="$1"
  shift
  t_capture_command OUT STATUS env PATH="${root}/bin:${PATH}" \
    STUB_CALLS="${root}/logs/uvx-calls" STUB_FAIL="${STUB_FAIL:-}" \
    bash "${root}/linux/scripts/refactor-python.sh" "$@"
}

report_dir() {
  local report
  for report in "$1"/logs/code-quality/python-refactor.*; do
    [ -d "${report}" ] && { printf '%s\n' "${report}"; return 0; }
  done
  return 1
}

t_case "default check reports both drifts without changing files"
root="$(new_root)" || exit 1
before="$(cat "${root}/app/one.py")"
run_refactor "${root}" app/one.py
t_assert_eq 1 "${STATUS}"
t_assert_eq "${before}" "$(cat "${root}/app/one.py")"
t_assert_contains "${OUT}" 'mode=check'
t_assert_contains "$(cat "${root}/logs/uvx-calls")" "ruff@${PIN} check --no-fix --no-unsafe-fixes -- app/one.py"
t_assert_contains "$(cat "${root}/logs/uvx-calls")" 'format --check --diff -- app/one.py'
report="$(report_dir "${root}")"
t_assert_ok test -s "${report}/refactor.log"
t_assert_ok test -f "${report}/changes.patch"
t_assert_eq 0 "$(wc -c < "${report}/changes.patch")"

t_case "a clean selected file passes the read-only check"
run_refactor "${root}" app/clean.py
t_assert_eq 0 "${STATUS}"
t_assert_contains "${OUT}" 'Ruff lint and format are clean'
t_assert_eq 'print("ok")' "$(cat "${root}/app/clean.py")"

t_case "an omitted file list selects tracked real Python without untracked files or heredocs"
root="$(new_root)" || exit 1
printf 'print("untracked")\n' > "${root}/app/untracked.py"
run_refactor "${root}"
t_assert_eq 1 "${STATUS}"
calls="$(cat "${root}/logs/uvx-calls")"
t_assert_contains "${calls}" 'app/clean.py'
t_assert_contains "${calls}" 'app/one.py'
t_assert_contains "${calls}" 'app/two.py'
t_assert_eq 0 "$(grep -c 'app/untracked.py\|probe.sh' "${root}/logs/uvx-calls")"

t_case "apply fixes only the selected tracked file and leaves unsafe candidates alone"
root="$(new_root)" || exit 1
second_before="$(cat "${root}/app/two.py")"
run_refactor "${root}" --apply app/one.py
t_assert_eq 0 "${STATUS}"
t_assert_contains "$(cat "${root}/app/one.py")" 'fixed_lint = fixed_format'
t_assert_contains "$(cat "${root}/app/one.py")" 'unsafe_candidate = 1'
t_assert_eq "${second_before}" "$(cat "${root}/app/two.py")"
t_assert_contains "$(cat "${root}/logs/uvx-calls")" 'check --fix --no-unsafe-fixes -- app/one.py'
t_assert_eq 'app/one.py' "$(git -C "${root}" diff --name-only)"
report="$(report_dir "${root}")"
t_assert_contains "$(cat "${report}/changes.patch")" 'app/one.py'
t_assert_eq 0 "$(grep -c 'app/two.py' "${report}/changes.patch")"

t_case "untracked and noncanonical paths fail before Ruff runs"
root="$(new_root)" || exit 1
printf 'print("untracked")\n' > "${root}/app/untracked.py"
run_refactor "${root}" --apply app/untracked.py
t_assert_eq 1 "${STATUS}"
t_assert_contains "${OUT}" 'not an exact tracked Python path'
run_refactor "${root}" --check ./app/one.py
t_assert_eq 1 "${STATUS}"
t_assert_contains "${OUT}" 'not an exact tracked Python path'
t_assert_fails test -e "${root}/logs/uvx-calls"

t_case "apply refuses unstaged and staged edits to selected files"
root="$(new_root)" || exit 1
printf '# local edit\n' >> "${root}/app/one.py"
run_refactor "${root}" --apply app/one.py
t_assert_eq 1 "${STATUS}"
t_assert_contains "${OUT}" 'unstaged changes'
t_assert_contains "$(cat "${root}/app/one.py")" '# local edit'
git -C "${root}" add -- app/one.py
run_refactor "${root}" --apply app/one.py
t_assert_eq 1 "${STATUS}"
t_assert_contains "${OUT}" 'staged changes'
t_assert_fails test -e "${root}/logs/uvx-calls"

t_case "failed Ruff is fatal and an attempted partial fix is rolled back"
root="$(new_root)" || exit 1
before="$(cat "${root}/app/one.py")"
STUB_FAIL=after-fix run_refactor "${root}" --apply app/one.py
t_assert_eq 1 "${STATUS}"
t_assert_contains "${OUT}" 'Ruff safe fixes failed'
t_assert_contains "${OUT}" 'Restored selected Python files after failure'
t_assert_eq "${before}" "$(cat "${root}/app/one.py")"
report="$(report_dir "${root}")"
t_assert_contains "$(cat "${report}/failed-attempt.patch")" 'app/one.py'
t_assert_eq '' "$(git -C "${root}" diff --name-only)"

t_summary
