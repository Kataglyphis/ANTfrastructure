#!/usr/bin/env bash
# lint-root.sh — the CONSUMER-ROOT contract, owned once for every lint gate.
#
# The callers — linux/scripts/lint-shell.sh, linux/scripts/lint-python.sh and
# linux/scripts/lint-dockerfiles.sh — each take an optional consumer root, for
# one reason: a submodule checkout puts them INSIDE the consumer, where a
# BASH_SOURCE-derived root resolves to ANTfrastructure and the gate grades the hub
# while reporting green over a tree nobody looked at.
# docs/shared-script-libraries.md#consumer-entry-points-that-are-not-libraries

# lint-workflows.sh predates this and spells the same idea as a POSITIONAL
# root; the other three spend their positional arguments on file names, so they
# spell it --root. Same semantics, same refusals, same protection.
#
# The bootstrap caches, versions.env and rule policies always come from the hub
# checkout regardless of the root; only the graded tree moves.
LINT_ROOT_GIVEN=0
LINT_ROOT_RAW=""
LINT_ROOT_PATH=""
LINT_ROOT_REST=()

_lint_root_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

# lint_root_take "$@" — consume --root <dir> / --root=<dir>; LINT_ROOT_REST
# keeps every other argument, in order, so a caller's own flags and file names
# are untouched.
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

# lint_root_resolve <default-root> — LINT_ROOT_PATH := the absolute tree to
# grade. A named root that does not exist, or is not a git checkout, is an
# ERROR: falling back to the default would grade a tree nobody named, and a
# non-checkout has no `git ls-files` answer to build a scope from.
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

# lint_root_begin <default-root> "$@" — take, then resolve. LINT_ROOT_GIVEN is
# 1 only when a root was NAMED, which is the flag every caller needs for the
# rule they all share: an EMPTY file list under an explicit root is an error,
# not a pass.
lint_root_begin() {
  local default_root="$1"
  shift
  lint_root_take "$@" || return 1
  lint_root_resolve "${default_root}" || return 1
}

# lint_root_tracked <root> <pathspec>... — NUL-separated tracked paths.
# git ls-files, never find: a vendored submodule (this very repo, at
# third_party/ANTfrastructure) is a GITLINK there, so a consumer's scope cannot
# quietly swallow the hub's own files, and untracked build output stays out.
lint_root_tracked() {
  local root="$1"
  shift
  git -C "${root}" ls-files -z -- "$@"
}
