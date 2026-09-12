#!/usr/bin/env bash
# lint-shell.sh — shellcheck gate for the repo's bash scripts.
#
# Catches the "undefined/typo'd function, quoting, bad redirection" failure
# class (docs/cross-build-verification.md#failure-classes-from-build-history, row 6)
# in seconds, instead of after a
# multi-hour QEMU cross build. The tree is kept clean at -S error; warnings are
# non-fatal here and ratcheted per file+code by verify_shellcheck_warnings.py.
#
# The shellcheck binary is bootstrapped on demand: a PATH copy is used ONLY when its
# version equals the pin (SHELLCHECK_VERSION / SHELLCHECK_*_SHA256 in versions.env);
# otherwise that pinned release is downloaded once into a version-keyed cache dir and
# SHA256-verified — the same pattern as lint-dockerfiles.sh /
# lint-workflows.sh. A failed bootstrap FAILS the gate (no silent skip: a
# skipped lint gate reads as green while checking nothing).
#
# Usage:
#   lint-shell.sh                 # check ALL bash under linux/{scripts,llm-stack,webserver} at -S error
#   lint-shell.sh a.sh b.sh ...   # check only the given files (pre-commit staged mode)
#   lint-shell.sh --root <dir>    # check a CONSUMER repo's shell scripts instead of this one
#   lint-shell.sh --warning ...   # additionally print warning-level findings (non-fatal)
#   lint-shell.sh --list-files    # print the root-relative file set and exit (the scope's one owner;
#                                 # verify_shellcheck_warnings.py ratchets warnings over exactly it)
#   lint-shell.sh --print-bin     # print the resolved shellcheck path and exit (the binary's one owner)
#
# --root is the same contract lint-workflows.sh documents, for the same reason:
# a submodule checkout puts this script INSIDE the consumer, where the default
# root resolves to ANTfrastructure and the gate grades the wrong tree while
# reporting green over one nobody looked at. The shellcheck bootstrap, its cache
# and versions.env always come from THIS repo regardless of the root.
#
# Under a root the file set is `git ls-files -- '*.sh'`, not a find: a vendored
# submodule (this very repo, at third_party/ANTfrastructure) is a GITLINK there, so
# the consumer's scope cannot quietly swallow the hub's own scripts — the same
# failure from the other direction. That the root must be a git checkout is
# therefore stated and checked, not assumed.
#
# And an EMPTY file list under an explicit root is an ERROR, never the
# "no shell scripts to check" pass below: this script skips paths that do not
# exist, so a scope built from a wrong prefix arrived here empty and reported
# green over nothing. That is the defect every line of this header is about.
#
# Exit status: non-zero iff any error-level finding exists (the gate),
# bootstrapping shellcheck fails, or an explicit root yields nothing to check.
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "${RED}✗${NC} %s\n" "$1"; }
info() { printf "  %s\n" "$1"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

# --root is parsed and resolved by the contract's one owner; the tree to grade
# is what comes back. Everything below is scoped to it; the hub paths above
# (CORE_DIR, the bootstrap cache) stay anchored to REPO_ROOT on purpose.
# shellcheck source=01-core/lint-root.sh
. "${CORE_DIR}/lint-root.sh"
lint_root_begin "${REPO_ROOT}" "$@" || exit 1
SCAN_ROOT="${LINT_ROOT_PATH}"
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

# ---------------------------------------------------------------------------
# Bootstrap of shellcheck (PATH copy only AT the pin; else pinned, SHA-verified download)
# ---------------------------------------------------------------------------
shellcheck_asset_and_sha() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64)
      printf 'shellcheck-%s.linux.x86_64.tar.xz %s\n' "${SHELLCHECK_VERSION}" "${SHELLCHECK_LINUX_X86_64_SHA256:-}" ;;
    MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64)
      # The plain .zip release asset is the Windows binary (shellcheck.exe).
      printf 'shellcheck-%s.zip %s\n' "${SHELLCHECK_VERSION}" "${SHELLCHECK_WINDOWS_SHA256:-}" ;;
    *) return 1 ;;
  esac
}

shellcheck_ensure() {
  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh"
  load_versions_env "${CORE_DIR}/versions.env"
  [ -n "${SHELLCHECK_VERSION:-}" ] || err "SHELLCHECK_VERSION is not set (versions.env not found?)."

  local asset expected_sha cache_root archive bin_name path_bin
  path_bin="$(command -v shellcheck || true)"
  if [ -n "${path_bin}" ] \
     && [ "$("${path_bin}" --version 2>/dev/null | sed -n 's/^version: //p')" = "${SHELLCHECK_VERSION#v}" ]; then
    SHELLCHECK_BIN="${path_bin}"
    return 0
  fi

  read -r asset expected_sha < <(shellcheck_asset_and_sha) \
    || err "Unsupported platform for shellcheck bootstrap ($(uname -s)/$(uname -m)); install shellcheck on PATH instead."
  [ -n "${expected_sha}" ] || err "No pinned shellcheck SHA256 for ${asset}; add one to versions.env."

  cache_root="${SHELLCHECK_CACHE_DIR:-${TMPDIR:-/tmp}}/shellcheck-${SHELLCHECK_VERSION}"
  bin_name="shellcheck"; case "${asset}" in *.zip) bin_name="shellcheck.exe" ;; esac
  SHELLCHECK_BIN="${cache_root}/${bin_name}"

  if [ ! -x "${SHELLCHECK_BIN}" ]; then
    # shellcheck source=01-core/downloads.sh
    source "${CORE_DIR}/downloads.sh" || err "downloads.sh not available for verified shellcheck fetch"
    mkdir -p "${cache_root}" || err "Cannot create shellcheck cache directory ${cache_root}"
    archive="${cache_root}/${asset}"
    download_verified_file \
      "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${asset}" \
      "${expected_sha}" \
      "${archive}" \
      || err "Verified download of ${asset} failed (checksum mismatch or network error)."
    case "${asset}" in
      *.tar.xz) tar -xJf "${archive}" -C "${cache_root}" --strip-components=1 \
                  "shellcheck-${SHELLCHECK_VERSION}/${bin_name}" || err "Extraction of ${asset} failed." ;;
      *.zip)    unzip -oq "${archive}" "${bin_name}" -d "${cache_root}" || err "Extraction of ${asset} failed." ;;
    esac
    rm -f "${archive}"
    chmod +x "${SHELLCHECK_BIN}"
  fi
}

if [ "${PRINT_BIN}" -eq 1 ]; then
  shellcheck_ensure
  printf '%s\n' "${SHELLCHECK_BIN}"
  exit 0
fi

# Default target set: every tracked .sh under linux/scripts, the runtime service
# scripts (llm-stack, webserver), the host-config operator tools, and the
# extension-less git hooks. host-config (2026-08-27) and git-hooks (2026-09-04)
# were both added after the same finding: a scope that quietly excludes the
# thing it was meant to protect. The ratchet asks THIS set.
# docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings

# Under --root the hub's four directories mean nothing, so the scope is the
# consumer's tracked *.sh instead — see lint_root_tracked for why that is
# git ls-files and never a find.
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

# Keep only existing shell scripts (a staged list may include deletions and
# files of other types).
#
# Extension-less scripts count too, IF they carry a shell shebang: git hooks are
# bash but cannot have a .sh suffix, so the commit hook
# (linux/host-config/git-hooks/pre-commit) would be checked by no gate at all.
# Its predecessor sat with an SC1072/SC1073 parse error until 2026-08-08 for
# exactly that reason. The shebang test keeps this from sweeping in READMEs and
# binaries. LOAD-BEARING: without it the live hook is unlinted.
# Note this only affects EXPLICITLY passed files — the default sweep above still
# discovers *.sh only, so the gate's default scope is unchanged.
#
# ${FILES[@]+...}: an empty find result leaves FILES unset, and expanding an
# unset array trips `set -u` on bash < 4.4 (harmless on 5.x, cheap to guard).
#
# Under an explicit root a relative name is the CONSUMER's, so it is anchored
# there rather than at the caller's cwd — and a name that then resolves to
# nothing is an ERROR, not a skip. The lenient skip above exists for the staged
# pre-commit list, which legitimately carries deletions; a caller that named a
# root and a file meant both, and dropping the file quietly shrinks the graded
# set while the banner still counts up to a pass.
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
  # Test the BASENAME, not the path: a directory component may carry a dot
  # (a path like ".githooks/pre-commit" matched the "has an extension" arm).
  case "${f##*/}" in
    *.sh) CHECK+=("${f}") ;;
    *.*)  ;;   # some other extension: not ours
    *)
      # No extension at all — admit it only on a shell shebang.
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
  # A root was NAMED and nothing came back: the caller handed this gate a tree
  # and would read the pass below as a verdict about it. Refuse instead.
  [ "${LINT_ROOT_GIVEN}" -eq 0 ] \
    || err "no shell script to check under ${SCAN_ROOT}; a root was given explicitly, so reporting green over an empty file list would be a verdict about nothing."
  pass "no shell scripts to check"
  exit 0
fi

shellcheck_ensure
info "shellcheck: ${SHELLCHECK_BIN} ($("${SHELLCHECK_BIN}" --version | sed -n 's/^version: //p'))"

# --- The gate: -S error must be clean. ---
error_files=()
for f in "${CHECK[@]}"; do
  "${SHELLCHECK_BIN}" -S error "${f}" >/dev/null 2>&1 || error_files+=("${f}")
done

if [ "${#error_files[@]}" -gt 0 ]; then
  fail "shellcheck -S error found ${#error_files[@]} file(s) with error-level findings:"
  for f in "${error_files[@]}"; do
    info "${f#"${SCAN_ROOT}"/}"
    "${SHELLCHECK_BIN}" -S error "${f}" 2>&1 | sed 's/^/    /' || true
  done
  exit 1
fi
pass "shellcheck -S error clean (${#CHECK[@]} file(s))"

# --- Fatal even though it is only a warning: SC2215. ---
#
# `cmd \` followed by a comment line ends the logical line, so the command runs
# with NO arguments and shellcheck reports the orphaned flags as SC2215 -- at
# warning level, which the gate above filters out. That is not a style nit: on
# 2026-08-28 it made the android ONNX Runtime build run `./build.sh` bare, which
# silently dropped every flag (Release, --no_telemetry, --allow_running_as_root)
# and killed the android stage after four hours of chain time.
sc2215_files=()
for f in "${CHECK[@]}"; do
  "${SHELLCHECK_BIN}" --include=SC2215 -S warning "${f}" >/dev/null 2>&1 || sc2215_files+=("${f}")
done

if [ "${#sc2215_files[@]}" -gt 0 ]; then
  fail "SC2215 (flag used as a command name -- bad line break) in ${#sc2215_files[@]} file(s):"
  for f in "${sc2215_files[@]}"; do
    info "${f#"${SCAN_ROOT}"/}"
    "${SHELLCHECK_BIN}" --include=SC2215 -S warning "${f}" 2>&1 | sed 's/^/    /' || true
  done
  exit 1
fi
pass "SC2215 clean (no flags orphaned by a bad line break)"

# --- Non-fatal warning report (opt-in). ---
if [ "${SHOW_WARNINGS}" -eq 1 ]; then
  warn_files=()
  for f in "${CHECK[@]}"; do
    "${SHELLCHECK_BIN}" -S warning "${f}" >/dev/null 2>&1 || warn_files+=("${f}")
  done
  if [ "${#warn_files[@]}" -gt 0 ]; then
    printf "${YELLOW}!${NC} %s file(s) carry warning-level findings (non-fatal):\n" "${#warn_files[@]}"
    for f in "${warn_files[@]}"; do info "${f#"${SCAN_ROOT}"/}"; done
  else
    pass "shellcheck -S warning also clean"
  fi
fi

exit 0
