#!/usr/bin/env bash
# lint-shell.sh — shellcheck gate for the repo's bash scripts.
#
# Catches the "undefined/typo'd function, quoting, bad redirection" failure
# class (see docs/cross-build-verification.md) in seconds, instead of after a
# multi-hour QEMU cross build. The tree is kept clean at -S error; warnings are
# reported but non-fatal (48 files still carry warning-level lint).
#
# Usage:
#   lint-shell.sh                 # check ALL bash under linux/{scripts,llm-stack,webserver} at -S error
#   lint-shell.sh a.sh b.sh ...   # check only the given files (pre-commit staged mode)
#   lint-shell.sh --warning ...   # additionally print warning-level findings (non-fatal)
#
# Exit status: non-zero iff any error-level finding exists (the gate).
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "${RED}✗${NC} %s\n" "$1"; }
info() { printf "  %s\n" "$1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SHOW_WARNINGS=0
FILES=()
for arg in "$@"; do
  case "${arg}" in
    --warning|-w) SHOW_WARNINGS=1 ;;
    *) FILES+=("${arg}") ;;
  esac
done

if ! command -v shellcheck >/dev/null 2>&1; then
  printf "${YELLOW}!${NC} shellcheck not installed — skipping (install shellcheck to enable this gate)\n"
  exit 0
fi

# Default target set: every tracked .sh under linux/scripts plus the runtime
# service scripts (llm-stack, webserver) that ship their own entrypoints.
if [ "${#FILES[@]}" -eq 0 ]; then
  mapfile -t FILES < <(find \
    "${REPO_ROOT}/linux/scripts" \
    "${REPO_ROOT}/linux/llm-stack" \
    "${REPO_ROOT}/linux/webserver" \
    -name '*.sh' -type f | sort)
fi

# Keep only existing .sh files (a staged list may include deletions / non-sh).
CHECK=()
for f in "${FILES[@]}"; do
  case "${f}" in *.sh) [ -f "${f}" ] && CHECK+=("${f}") ;; esac
done

if [ "${#CHECK[@]}" -eq 0 ]; then
  pass "no shell scripts to check"
  exit 0
fi

# --- The gate: -S error must be clean. ---
error_files=()
for f in "${CHECK[@]}"; do
  shellcheck -S error "${f}" >/dev/null 2>&1 || error_files+=("${f}")
done

if [ "${#error_files[@]}" -gt 0 ]; then
  fail "shellcheck -S error found ${#error_files[@]} file(s) with error-level findings:"
  for f in "${error_files[@]}"; do
    info "${f#"${REPO_ROOT}"/}"
    shellcheck -S error "${f}" 2>&1 | sed 's/^/    /' || true
  done
  exit 1
fi
pass "shellcheck -S error clean (${#CHECK[@]} file(s))"

# --- Non-fatal warning report (opt-in). ---
if [ "${SHOW_WARNINGS}" -eq 1 ]; then
  warn_files=()
  for f in "${CHECK[@]}"; do
    shellcheck -S warning "${f}" >/dev/null 2>&1 || warn_files+=("${f}")
  done
  if [ "${#warn_files[@]}" -gt 0 ]; then
    printf "${YELLOW}!${NC} %s file(s) carry warning-level findings (non-fatal):\n" "${#warn_files[@]}"
    for f in "${warn_files[@]}"; do info "${f#"${REPO_ROOT}"/}"; done
  else
    pass "shellcheck -S warning also clean"
  fi
fi

exit 0
