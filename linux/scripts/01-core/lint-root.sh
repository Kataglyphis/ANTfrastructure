#!/usr/bin/env bash
# Consumer-root contract for linux/scripts/lint-shell.sh, lint-python.sh and lint-dockerfiles.sh. docs/shared-script-libraries.md#consumer-entry-points-that-are-not-libraries

# Only the graded tree moves; caches, versions.env and rule policies always come from the hub.
LINT_ROOT_GIVEN=0
LINT_ROOT_RAW=""
LINT_ROOT_PATH=""
LINT_ROOT_REST=()

_lint_root_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

# lint_root_take "$@": consumes --root <dir> / --root=<dir>; LINT_ROOT_REST keeps the rest in order.
lint_root_take() {
  local arg want=0
  LINT_ROOT_GIVEN=0
  LINT_ROOT_RAW=""
  LINT_ROOT_REST=()
  for arg in "$@"; do
    if [ "${want}" -eq 1 ]; then
      LINT_ROOT_RAW="${arg}"; LINT_ROOT_GIVEN=1; want=0; continue
    fi
    case "${arg}" in
      --root)   want=1 ;;
      --root=*) LINT_ROOT_RAW="${arg#--root=}"; LINT_ROOT_GIVEN=1 ;;
      *)        LINT_ROOT_REST+=("${arg}") ;;
    esac
  done
  [ "${want}" -eq 0 ] || _lint_root_die "--root needs a directory argument."
}

# lint_root_resolve <default-root>: a named root that is missing or not a git checkout errors, never falls back.
lint_root_resolve() {
  if [ "${LINT_ROOT_GIVEN}" -ne 1 ]; then
    LINT_ROOT_PATH="$1"
    return 0
  fi
  LINT_ROOT_PATH="$(cd "${LINT_ROOT_RAW}" 2>/dev/null && pwd)" \
    || _lint_root_die "lint root not found: ${LINT_ROOT_RAW}" || return 1
  git -C "${LINT_ROOT_PATH}" rev-parse --git-dir >/dev/null 2>&1 \
    || _lint_root_die "--root ${LINT_ROOT_PATH} is not a git checkout; a consumer's scope is read from git ls-files." \
    || return 1
}

# LINT_ROOT_GIVEN=1 only for a named root, under which callers treat an empty file list as an error.
lint_root_begin() {
  local default_root="$1"
  shift
  lint_root_take "$@" || return 1
  lint_root_resolve "${default_root}" || return 1
}

# git ls-files, never find: the hub is a gitlink in a consumer, and untracked output stays out.
lint_root_tracked() {
  local root="$1"
  shift
  git -C "${root}" ls-files -z -- "$@"
}
