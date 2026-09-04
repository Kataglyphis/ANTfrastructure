#!/usr/bin/env bash
# lint-shell.sh — shellcheck gate for the repo's bash scripts.
#
# Catches the "undefined/typo'd function, quoting, bad redirection" failure
# class (see docs/cross-build-verification.md) in seconds, instead of after a
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
#   lint-shell.sh --warning ...   # additionally print warning-level findings (non-fatal)
#   lint-shell.sh --list-files    # print the repo-relative file set and exit (the scope's one owner;
#                                 # verify_shellcheck_warnings.py ratchets warnings over exactly it)
#   lint-shell.sh --print-bin     # print the resolved shellcheck path and exit (the binary's one owner)
#
# Exit status: non-zero iff any error-level finding exists (the gate) or
# bootstrapping shellcheck fails.
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "${RED}✗${NC} %s\n" "$1"; }
info() { printf "  %s\n" "$1"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

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
# scripts (llm-stack, webserver) that ship their own entrypoints, and the
# host-config operator tools.
#
# host-config was NOT swept until 2026-08-27. Seven scripts sat outside the
# gate -- including install-nerdctl-full.sh and the two ghcr tools, i.e. the
# ones that upgrade the daemon and DELETE from the registry. They happened to
# be clean, which is luck, not coverage: this repo's recurring failure is a
# gate whose scope quietly excludes the thing it was meant to protect.
if [ "${#FILES[@]}" -eq 0 ]; then
  mapfile -t FILES < <(find \
    "${REPO_ROOT}/linux/scripts" \
    "${REPO_ROOT}/linux/host-config" \
    "${REPO_ROOT}/linux/llm-stack" \
    "${REPO_ROOT}/linux/webserver" \
    -name '*.sh' -type f | sort)
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
CHECK=()
for f in ${FILES[@]+"${FILES[@]}"}; do
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
  for f in ${CHECK[@]+"${CHECK[@]}"}; do printf '%s\n' "${f#"${REPO_ROOT}"/}"; done
  exit 0
fi

if [ "${#CHECK[@]}" -eq 0 ]; then
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
    info "${f#"${REPO_ROOT}"/}"
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
    info "${f#"${REPO_ROOT}"/}"
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
    for f in "${warn_files[@]}"; do info "${f#"${REPO_ROOT}"/}"; done
  else
    pass "shellcheck -S warning also clean"
  fi
fi

exit 0
