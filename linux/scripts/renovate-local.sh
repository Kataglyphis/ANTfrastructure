#!/usr/bin/env bash
# renovate-local.sh - the family's dependency-upgrade tool: Renovate as a LOCAL
# CLI (owner directive 2026-09-09). It DETECTS; --apply is the other half, and
# that half is git. Before changing it read
# docs/dependency-updates.md#before-you-change-the-script first.
#
#   renovate-local.sh [--refresh] [<root>]       report what is behind (default)
#   renovate-local.sh --apply [--dry-run] <root> move the gitlinks / show the plan
#   renovate-local.sh --managers <csv> <root>    default: git-submodules
#   renovate-local.sh --print-bin                the resolved renovate.js
set -uo pipefail

err() { printf 'renovate-local.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# "blank line, explanation, indented list" -- what every refusal below prints.
# Args: the explanation lines, then --, then the items. Returns 1 WITHOUT
# printing when there are no items, so callers write `if note_listing ...`
# instead of repeating an emptiness guard around every call.
note_listing() {
  local -a text=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do text+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  [ $# -gt 0 ] || return 1
  note ""
  if [ "${#text[@]}" -gt 0 ]; then printf '%s\n' "${text[@]}"; fi
  printf '  %s\n' "$@"
  return 0
}

HUB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=01-core/versions.env disable=SC1091
. "${HUB_ROOT}/linux/scripts/01-core/versions.env" 2>/dev/null \
  || err "cannot read the version pins at linux/scripts/01-core/versions.env"

# shellcheck source=01-core/platform.sh disable=SC1091
. "${HUB_ROOT}/linux/scripts/01-core/platform.sh" 2>/dev/null \
  || err "cannot load 01-core/platform.sh (needed for arch_normalize)"

: "${RENOVATE_NODE_VERSION:?RENOVATE_NODE_VERSION missing from versions.env}"
: "${RENOVATE_VERSION:?RENOVATE_VERSION missing from versions.env}"

MODE=report
MANAGERS=git-submodules
TARGET=""
DRY_RUN=0
REFRESH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)     MODE=apply ;;
    --report)    MODE=report ;;
    --dry-run)   DRY_RUN=1 ;;
    --refresh)   REFRESH=1 ;;
    --print-bin) MODE=print-bin ;;
    --managers)  shift; [ $# -gt 0 ] || err "--managers needs a value"; MANAGERS="$1" ;;
    --managers=*) MANAGERS="${1#*=}" ;;
    -h|--help)   sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)          err "unknown option: $1" ;;
    *)           [ -z "${TARGET}" ] || err "more than one repo root given"; TARGET="$1" ;;
  esac
  shift
done

TARGET="${TARGET:-$PWD}"
[ -d "${TARGET}" ] || err "not a directory: ${TARGET}"
TARGET="$(cd "${TARGET}" && pwd)"
git -C "${TARGET}" rev-parse --git-dir >/dev/null 2>&1 || err "not a git repo: ${TARGET}"

# --------------------------------------------------------------------------
# Bootstrap: a pinned, checksum-verified Node plus a pinned Renovate, cached
# per version. Same shape as the shellcheck and gitleaks bootstraps, and for the
# same reason: a tool resolved from PATH at an unknown version turns a red gate
# into an argument about whose machine is right.
# --------------------------------------------------------------------------
# A python that actually RUNS. On a Windows host `python3` on PATH is the
# Microsoft Store stub, which exits 49 on `-c pass` -- so probe, do not assume.
PY_BIN="${PREFLIGHT_PYTHON:-python3}"
if ! "${PY_BIN}" -c 'pass' >/dev/null 2>&1; then
  if python -c 'pass' >/dev/null 2>&1; then
    PY_BIN=python
  else
    err "no working python3 (tried '${PY_BIN}' and 'python'); set PREFLIGHT_PYTHON"
  fi
fi

CACHE_ROOT="${RENOVATE_LOCAL_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/kataglyphis}"
NODE_DIR="${CACHE_ROOT}/node-${RENOVATE_NODE_VERSION}"
NPM_PREFIX="${CACHE_ROOT}/renovate-${RENOVATE_VERSION}"
RENOVATE_JS="${NPM_PREFIX}/lib/node_modules/renovate/dist/renovate.js"

node_major() { "$1" --version 2>/dev/null | sed -e 's/^v//' -e 's/\..*//'; }

# arch_normalize is the repo's one owner of the x86_64/amd64/aarch64/arm64
# spelling problem (01-core/platform.sh). Rolling another `case "$(uname -m)"`
# here is exactly the copy the duplication gate exists to catch -- it flagged the
# first version of this function against platform.sh and lib/wasm-opt.sh.
node_arch_asset() {
  local arch
  arch="$(arch_normalize "$(uname -m)")"
  case "${arch}" in
    amd64) printf 'linux-x64 %s\n'   "${RENOVATE_NODE_LINUX_X64_SHA256:-}" ;;
    arm64) printf 'linux-arm64 %s\n' "${RENOVATE_NODE_LINUX_ARM64_SHA256:-}" ;;
    *) err "no pinned Node asset for ${arch}; install Node ${RENOVATE_NODE_VERSION}+ yourself and re-run" ;;
  esac
}

bootstrap_node() {
  # A PATH copy is used ONLY when it is new enough. Renovate's own engine check
  # would otherwise fail late and obscurely.
  local path_node
  path_node="$(command -v node || true)"
  # Major must MATCH the pin, not merely exceed it: Renovate declares
  # engines.node "^24.11.0", so this repo's own NODE_VERSION=26.8.1 is too NEW.
  local want_major="${RENOVATE_NODE_VERSION%%.*}"
  if [ -n "${path_node}" ] && [ "$(node_major "${path_node}")" = "${want_major}" ] 2>/dev/null; then
    NODE_BIN="${path_node}"
    return 0
  fi
  NODE_BIN="${NODE_DIR}/bin/node"
  [ -x "${NODE_BIN}" ] && return 0

  local asset sha url tmp
  read -r asset sha <<<"$(node_arch_asset)"
  [ -n "${sha}" ] || err "no SHA256 pinned for node-v${RENOVATE_NODE_VERSION}-${asset}"
  url="https://nodejs.org/dist/v${RENOVATE_NODE_VERSION}/node-v${RENOVATE_NODE_VERSION}-${asset}.tar.xz"
  tmp="$(mktemp -d)" || err "mktemp failed"

  note "bootstrapping node ${RENOVATE_NODE_VERSION} (${asset}) into ${NODE_DIR}"
  curl -fsSL -o "${tmp}/node.tar.xz" "${url}" || { rm -rf "${tmp}"; err "download failed: ${url}"; }
  local got
  got="$(sha256sum "${tmp}/node.tar.xz" | cut -d' ' -f1)"
  if [ "${got}" != "${sha}" ]; then
    rm -rf "${tmp}"
    err "checksum mismatch for node-v${RENOVATE_NODE_VERSION}-${asset}: expected ${sha}, got ${got}"
  fi
  mkdir -p "${NODE_DIR}"
  tar -xJf "${tmp}/node.tar.xz" -C "${NODE_DIR}" --strip-components=1 \
    || { rm -rf "${tmp}"; err "extract failed"; }
  rm -rf "${tmp}"
  [ -x "${NODE_BIN}" ] || err "node did not land at ${NODE_BIN}"
}

bootstrap_renovate() {
  [ -f "${RENOVATE_JS}" ] && return 0
  note "installing renovate ${RENOVATE_VERSION} into ${NPM_PREFIX}"
  # npm_config_prefix keeps this in a user-owned dir: no sudo, and nothing
  # global is touched on a shared machine.
  PATH="$(dirname "${NODE_BIN}"):${PATH}" npm_config_prefix="${NPM_PREFIX}" \
    "$(dirname "${NODE_BIN}")/npm" install -g "renovate@${RENOVATE_VERSION}" \
    --no-fund --no-audit --loglevel=error \
    || err "npm install of renovate@${RENOVATE_VERSION} failed"
  [ -f "${RENOVATE_JS}" ] || err "renovate did not land at ${RENOVATE_JS}"
}

bootstrap_node
bootstrap_renovate

if [ "${MODE}" = print-bin ]; then
  printf '%s\n' "${RENOVATE_JS}"
  exit 0
fi

# --------------------------------------------------------------------------
# Report: what is behind, according to the repo's OWN renovate config.
#
# Renovate's console output does NOT name the pending updates at info level --
# they appear only inside a "packageFiles with updates" blob at debug. So this
# asks for the machine-readable report instead (RENOVATE_REPORT_TYPE=file) and
# renders it. Reading a JSON report is also what makes --apply able to move only
# what is actually behind, rather than every submodule that declares a branch.
# --------------------------------------------------------------------------
REPORT_JSON=""

run_renovate() {
  REPORT_JSON="$(mktemp)" || err "mktemp failed"
  # --refresh drops the lookup cache first. A cache written before a push reports
  # the OLD tip as "available", i.e. a downgrade presented as an update -- seen
  # on 2026-09-09 with 46b73e33 -> 1fef6f28, which is its own parent.
  if [ "${REFRESH}" -eq 1 ]; then
    note "dropping the lookup cache at ${CACHE_ROOT}/base"
    rm -rf "${CACHE_ROOT:?}/base"
  fi
  # RENOVATE_BASE_DIR keeps Renovate's scratch out of the repo being graded.
  # A token is deliberately NOT required: the git-submodules manager uses the
  # git-refs datasource, i.e. anonymous `git ls-remote`, and ssh remotes are
  # rewritten to https automatically.
  ( cd "${TARGET}" \
    && RENOVATE_BASE_DIR="${CACHE_ROOT}/base" \
       LOG_LEVEL="${RENOVATE_LOG_LEVEL:-warn}" \
       RENOVATE_REPORT_TYPE=file \
       RENOVATE_REPORT_PATH="${REPORT_JSON}" \
       RENOVATE_ONBOARDING=false \
       RENOVATE_REQUIRE_CONFIG=optional \
       "${NODE_BIN}" "${RENOVATE_JS}" \
         --platform=local \
         --enabled-managers="${MANAGERS}" ) \
    || err "renovate exited non-zero"
  [ -s "${REPORT_JSON}" ] || err "renovate wrote no report to ${REPORT_JSON}"
}

# Prints one "<depName>\t<current>\t<new>" line per pending update, nothing else.
# Kept as its own function so both the human table and --apply read ONE parse.
pending_updates() {
  "${PY_BIN}" - "${REPORT_JSON}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    report = json.load(fh)
for repo in (report.get("repositories") or {}).values():
    for files in (repo.get("packageFiles") or {}).values():
        for f in files:
            for dep in f.get("deps") or []:
                for up in dep.get("updates") or []:
                    new = up.get("newDigest") or up.get("newValue") or ""
                    cur = dep.get("currentDigest") or dep.get("currentValue") or ""
                    print("%s\t%s\t%s" % (dep.get("depName") or "?", cur[:12], new[:12]))
                    break
PY
}

run_report() {
  local n=0
  while IFS=$'\t' read -r dep cur new; do
    [ -n "${dep}" ] || continue
    [ "${n}" -eq 0 ] && printf '%-38s %-14s %s\n' 'DEPENDENCY' 'CURRENT' 'AVAILABLE'
    printf '%-38s %-14s %s\n' "${dep}" "${cur}" "${new}"
    n=$((n + 1))
  done < <(pending_updates)
  if [ "${n}" -eq 0 ]; then
    note "up to date: nothing behind for manager(s) ${MANAGERS}"
  else
    note ""
    note "${n} update(s) available (manager(s): ${MANAGERS})"
  fi
}

# --------------------------------------------------------------------------
# Apply: the half Renovate cannot do. Explicit paths only, branch declared only.
# --------------------------------------------------------------------------
# The submodule paths in .gitmodules, split by whether they declare a branch --
# the single question --apply turns on. ONE walk with the predicate as the
# argument, because two walks were a copy of each other down to the sed.
#   submodule_paths with-branch     -> paths that name a branch to track
#   submodule_paths without-branch  -> paths where --remote would fall back to
#                                      the remote's default branch
submodule_paths() {
  local want="$1" name path
  git -C "${TARGET}" config -f .gitmodules --name-only --get-regexp '\.path$' 2>/dev/null \
  | sed -e 's/^submodule\.//' -e 's/\.path$//' \
  | while read -r name; do
      if git -C "${TARGET}" config -f .gitmodules --get "submodule.${name}.branch" >/dev/null 2>&1; then
        [ "${want}" = with-branch ] || continue
      else
        [ "${want}" = without-branch ] || continue
      fi
      path="$(git -C "${TARGET}" config -f .gitmodules --get "submodule.${name}.path" 2>/dev/null)"
      if [ -n "${path}" ]; then printf '%s\n' "${path}"; fi
    done
}

# The apply half hands three lists between four functions. Globals, because bash
# cannot return a list and a $() round-trip would re-run the classification --
# which costs one git call per submodule.
APPLY_PATHS=(); APPLY_REFUSED=(); APPLY_UNMATCHED=()
APPLY_DIRTY=(); APPLY_EOL=()
GIT_BIN=git; GIT_TARGET=""

# Which submodules to move: BOTH behind (Renovate says so) AND declaring a branch
# (.gitmodules says so). Neither half is sufficient alone.
select_apply_targets() {
  local -a behind=() declared=() branchless=()
  local dep _cur _new pth b d

  while IFS=$'\t' read -r dep _cur _new; do
    [ -n "${dep}" ] && behind+=("${dep}")
  done < <(pending_updates)
  while IFS= read -r pth; do [ -n "${pth}" ] && declared+=("${pth}"); done < <(submodule_paths with-branch)
  while IFS= read -r pth; do [ -n "${pth}" ] && branchless+=("${pth}"); done < <(submodule_paths without-branch)

  APPLY_PATHS=(); APPLY_REFUSED=(); APPLY_UNMATCHED=()
  for b in ${behind[@]+"${behind[@]}"}; do
    for d in ${declared[@]+"${declared[@]}"}; do
      [ "${b}" = "${d}" ] && { APPLY_PATHS+=("${b}"); continue 2; }
    done
    for d in ${branchless[@]+"${branchless[@]}"}; do
      [ "${b}" = "${d}" ] && { APPLY_REFUSED+=("${b}"); continue 2; }
    done
    APPLY_UNMATCHED+=("${b}")
  done
}

# Genuinely dirty, or merely read by the wrong git? --ignore-cr-at-eol separates
# them: a Windows checkout (core.autocrlf=true) read by a git without that setting
# reports EVERY text file as modified, and the two cases need opposite responses.
classify_apply_paths() {
  APPLY_DIRTY=(); APPLY_EOL=()
  local q
  for q in "${APPLY_PATHS[@]}"; do
    [ -e "${TARGET}/${q}/.git" ] || continue          # not initialised; git handles it
    if ! "${GIT_BIN}" -C "${GIT_TARGET}/${q}" diff --quiet --ignore-cr-at-eol HEAD 2>/dev/null; then
      APPLY_DIRTY+=("${q}")
    elif ! "${GIT_BIN}" -C "${GIT_TARGET}/${q}" diff --quiet HEAD 2>/dev/null; then
      APPLY_EOL+=("${q}")
    fi
  done
}

# The two halves of this script need DIFFERENT gits on the documented Windows
# workflow: the report needs node, which lives in WSL, while the checkout needs the
# git that WROTE the working tree. WSL can call the Windows git, so switch to it
# rather than refusing.
select_git_for_tree() {
  GIT_BIN=git; GIT_TARGET="${TARGET}"
  classify_apply_paths
  [ "${#APPLY_EOL[@]}" -gt 0 ] || return 0
  command -v git.exe >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0

  local win_target
  win_target="$(wslpath -w "${TARGET}" 2>/dev/null || true)"
  [ -n "${win_target}" ] || return 0
  git.exe -C "${win_target}" rev-parse --git-dir >/dev/null 2>&1 || return 0

  GIT_BIN=git.exe
  GIT_TARGET="${win_target}"
  note ""
  note "this tree was checked out by the Windows git; using it for the checkout"
  note "half (${win_target}). A Linux-git checkout over it aborts mid-run."
  classify_apply_paths
}

# PRE-FLIGHT, learned the hard way on 2026-09-09: `git submodule update --remote`
# over several paths is NOT ATOMIC. It walks them in order, and one dirty submodule
# makes git abort THAT checkout while the ones already done stay moved -- a
# half-applied superproject with a non-zero exit. Refusing up front is the only way
# to keep this all-or-nothing.
assert_targets_applyable() {
  if note_listing \
      "REFUSING to apply: this git disagrees with the checkout about line endings." \
      "Every text file in the submodule(s) below differs by CR only, which means" \
      "the tree was written by a DIFFERENT git (the classic case: a Windows" \
      "checkout with core.autocrlf=true, read from WSL without git.exe on PATH):" \
      -- ${APPLY_EOL[@]+"${APPLY_EOL[@]}"}; then
    note ""
    note "The REPORT half is safe from anywhere -- it only reads. Run --apply with the"
    note "git that owns the working tree (on Windows: Git Bash or PowerShell)."
    err "wrong git for this working tree"
  fi
  if note_listing \
      "REFUSING to apply: these submodules have local changes, and a --remote" \
      "checkout over them aborts mid-run and leaves the others already moved:" \
      -- ${APPLY_DIRTY[@]+"${APPLY_DIRTY[@]}"}; then
    err "clean or stash them, then re-run"
  fi
}

run_apply() {
  [ -f "${TARGET}/.gitmodules" ] || { note "no .gitmodules in ${TARGET}; nothing to apply"; return 0; }
  select_apply_targets

  # A dep that is behind but is not a submodule here -- an npm package, a Dockerfile
  # tag. Saying so is the point: --apply moves gitlinks and nothing else, and silence
  # would read as "handled".
  note_listing \
    "behind, but NOT a submodule of this repo -- --apply does not touch these," \
    "update them where they are declared:" \
    -- ${APPLY_UNMATCHED[@]+"${APPLY_UNMATCHED[@]}"} || true

  if note_listing \
      "REFUSED - behind, but no \`branch =\` in .gitmodules. A bare --remote would" \
      "walk these to the remote's DEFAULT branch, which is not the line the pin" \
      "was taken from (the FUZZTEST case):" \
      -- ${APPLY_REFUSED[@]+"${APPLY_REFUSED[@]}"}; then
    note "Move one of these by hand, deliberately, or give it a branch entry."
  fi

  [ "${#APPLY_PATHS[@]}" -gt 0 ] || { note ""; note "nothing to apply"; return 0; }

  select_git_for_tree
  assert_targets_applyable

  # --dry-run stops HERE, after the pre-flight and never before it: the value of a
  # plan is that it ran the checks that would block the real thing.
  note ""
  if [ "${DRY_RUN}" -eq 1 ]; then
    note "--dry-run: WOULD update ${#APPLY_PATHS[@]} submodule(s) to the tip of the"
    note "branch .gitmodules names for them, and touch nothing else:"
    printf '  %s\n' "${APPLY_PATHS[@]}"
    note ""
    note "the command that would run:"
    note "  ${GIT_BIN} -C ${GIT_TARGET} submodule update --remote -- ${APPLY_PATHS[*]}"
    return 0
  fi

  note "updating ${#APPLY_PATHS[@]} submodule(s) to the tip of the branch they name:"
  printf '  %s\n' "${APPLY_PATHS[@]}"
  # Explicit paths, and NO --recursive. Both deliberate; see the header.
  "${GIT_BIN}" -C "${GIT_TARGET}" submodule update --remote -- "${APPLY_PATHS[@]}" \
    || err "git submodule update --remote failed -- the superproject may be
PARTIALLY updated: check \`git status\` and restore with
\`git submodule update --init <path>\`"

  note ""
  note "what moved (review before committing):"
  "${GIT_BIN}" -C "${GIT_TARGET}" submodule summary -- "${APPLY_PATHS[@]}" 2>/dev/null || true
  note ""
  note "Nothing is staged or committed. Stage the paths you reviewed."
}

cleanup() {
  # `return 0` on purpose: a trailing `[ x ] && cmd` makes the function exit
  # with the TEST's status, and this one runs from a trap.
  [ -n "${REPORT_JSON}" ] && rm -f "${REPORT_JSON}"
  return 0
}
trap cleanup EXIT

run_renovate
case "${MODE}" in
  report) run_report ;;
  apply)  run_report; run_apply ;;
  *)      err "unreachable mode ${MODE}" ;;
esac
