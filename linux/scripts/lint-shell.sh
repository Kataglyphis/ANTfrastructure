#!/usr/bin/env bash
# [--root <dir>] [--warning] [--list-files|--print-bin] [file ...]: pinned shellcheck at -S error; a failed bootstrap fails.
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "${RED}✗${NC} %s\n" "$1"; }
info() { printf "  %s\n" "$1"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

# Everything below is scoped to the root; CORE_DIR and the bootstrap cache stay in REPO_ROOT.
# shellcheck source=01-core/lint-root.sh
. "${CORE_DIR}/lint-root.sh"
lint_scope_begin SCAN_ROOT "${REPO_ROOT}" "$@" || exit 1
set -- ${LINT_ROOT_REST[@]+"${LINT_ROOT_REST[@]}"}

SHOW_WARNINGS=0
LIST_FILES=0
PRINT_BIN=0
FILES=()
for arg in "$@"; do
  case "${arg}" in
    --warning|-w) SHOW_WARNINGS=1 ;;
    --list-files) LIST_FILES=1 ;;
    --print-bin) PRINT_BIN=1 ;;
    *) FILES+=("${arg}") ;;
  esac
done

# Bootstrapping shellcheck: PATH copy only at the pin, else a pinned, SHA-verified download
# shellcheck source=01-core/lint-tool-release.sh
source "${CORE_DIR}/lint-tool-release.sh"

shellcheck_ensure() {
  lint_tool_ensure shellcheck SHELLCHECK_BIN
}

if [ "${PRINT_BIN}" -eq 1 ]; then
  shellcheck_ensure
  printf '%s\n' "${SHELLCHECK_BIN}"
  exit 0
fi

# The warning ratchet grades exactly this set. docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings

# Under --root the scope is the consumer's tracked *.sh (see lint_root_tracked).
if [ "${#FILES[@]}" -eq 0 ] && [ "${LINT_ROOT_GIVEN}" -eq 1 ]; then
  while IFS= read -r -d '' _tracked; do
    FILES+=("${SCAN_ROOT}/${_tracked}")
  done < <(lint_root_tracked "${SCAN_ROOT}" '*.sh')
elif [ "${#FILES[@]}" -eq 0 ]; then
  mapfile -t FILES < <(find \
    "${REPO_ROOT}/linux/scripts" \
    "${REPO_ROOT}/linux/host-config" \
    "${REPO_ROOT}/linux/llm-stack" \
    "${REPO_ROOT}/linux/webserver" \
    \( -name '*.sh' -o -path "${REPO_ROOT}/linux/host-config/git-hooks/*" \) \
    -type f | sort)
fi

# Shebang-checked extension-less files keep git hooks linted; under a root a missing named file is an error.
CHECK=()
for f in ${FILES[@]+"${FILES[@]}"}; do
  if [ "${LINT_ROOT_GIVEN}" -eq 1 ]; then
    case "${f}" in
      /*|[A-Za-z]:[/\\]*) ;;
      *) f="${SCAN_ROOT}/${f}" ;;
    esac
    [ -e "${f}" ] || err "no such path under ${SCAN_ROOT}: ${f}"
  fi
  [ -f "${f}" ] || continue
  # The basename, not the path: a directory like .githooks/ carries a dot.
  case "${f##*/}" in
    *.sh) CHECK+=("${f}") ;;
    *.*)  ;;   # some other extension: not ours
    *)
      # No extension at all — admit it only on a shell shebang. LOAD-BEARING: the live hook has none.
      case "$(head -c 128 "${f}" 2>/dev/null | head -n 1 | tr -d '\r')" in
        '#!'*[bd]'ash'|'#!'*[bd]'ash '*|'#!/bin/sh'|'#!/bin/sh '*|'#!'*'env sh'|'#!'*'env '[bd]'ash')
          CHECK+=("${f}") ;;
      esac
      ;;
  esac
done

if [ "${LIST_FILES}" -eq 1 ]; then
  for f in ${CHECK[@]+"${CHECK[@]}"}; do printf '%s\n' "${f#"${SCAN_ROOT}"/}"; done
  exit 0
fi

if [ "${#CHECK[@]}" -eq 0 ]; then
  # A named root with nothing to check must not read as a pass.
  [ "${LINT_ROOT_GIVEN}" -eq 0 ] \
    || err "no shell script to check under ${SCAN_ROOT}; a root was given explicitly, so reporting green over an empty file list would be a verdict about nothing."
  pass "no shell scripts to check"
  exit 0
fi

shellcheck_ensure
info "shellcheck: ${SHELLCHECK_BIN} ($("${SHELLCHECK_BIN}" --version | sed -n 's/^version: //p'))"

# shellcheck source=linux/scripts/lib-ordered-jobs.sh
. "${REPO_ROOT}/linux/scripts/lib-ordered-jobs.sh"
# LINT_SHELL_JOBS: shellcheck processes at once, default one per CPU; 1 checks the files in turn.
LINT_JOBS="$(oj_count LINT_SHELL_JOBS)" || exit 2

# <out-array> <shellcheck args...>: the CHECK files those args fail, sorted; one process per file, so any non-zero exit counts.
sc_failing_files() {
  local -n _sff_out=$1
  shift
  local verdicts n
  verdicts="$(printf '%s\0' "${CHECK[@]}" \
    | xargs -0 -r -n 1 -P "${LINT_JOBS}" bash -c \
        '"$0" "$@" >/dev/null 2>&1 && echo "ok ${@: -1}" || echo "fail ${@: -1}"' "${SHELLCHECK_BIN}" "$@")" || true
  # One verdict per file, or a runner that died early would read as clean.
  n="$(printf '%s\n' "${verdicts}" | grep -c -e '^ok ' -e '^fail ' || true)"
  [ "${n}" -eq "${#CHECK[@]}" ] || err "shellcheck reported on ${n} of ${#CHECK[@]} file(s); refusing to grade an incomplete run"
  mapfile -t _sff_out < <(printf '%s\n' "${verdicts}" | sed -n 's/^fail //p' | LC_ALL=C sort)
}

sc_report_fatal_files() {
  local -n _srff_files="$1"
  local heading="$2" f
  shift 2
  if [ "${#_srff_files[@]}" -gt 0 ]; then
    fail "${heading}"
    for f in "${_srff_files[@]}"; do
      info "${f#"${SCAN_ROOT}"/}"
      "${SHELLCHECK_BIN}" "$@" "${f}" 2>&1 | sed 's/^/    /' || true
    done
    exit 1
  fi
}

# The gate: -S error must be clean
error_files=()
sc_failing_files error_files -S error

sc_report_fatal_files error_files "shellcheck -S error found ${#error_files[@]} file(s) with error-level findings:" -S error
pass "shellcheck -S error clean (${#CHECK[@]} file(s))"

# SC2215 is fatal though a warning: a comment after `cmd \` runs cmd without its flags.
sc2215_files=()
sc_failing_files sc2215_files --include=SC2215 -S warning

sc_report_fatal_files sc2215_files "SC2215 (flag used as a command name -- bad line break) in ${#sc2215_files[@]} file(s):" --include=SC2215 -S warning
pass "SC2215 clean (no flags orphaned by a bad line break)"

# Non-fatal warning report (opt-in)
if [ "${SHOW_WARNINGS}" -eq 1 ]; then
  warn_files=()
  sc_failing_files warn_files -S warning
  if [ "${#warn_files[@]}" -gt 0 ]; then
    printf "${YELLOW}!${NC} %s file(s) carry warning-level findings (non-fatal):\n" "${#warn_files[@]}"
    for f in "${warn_files[@]}"; do info "${f#"${SCAN_ROOT}"/}"; done
  else
    pass "shellcheck -S warning also clean"
  fi
fi

exit 0
