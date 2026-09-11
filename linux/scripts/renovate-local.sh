#!/usr/bin/env bash
# renovate-local.sh - the family's dependency-upgrade tool: Renovate as a LOCAL
# CLI (owner directive 2026-09-09). Renovate DETECTS; this script APPLIES, for
# every ecosystem the repo has. Read
# docs/dependency-updates.md#before-you-change-the-script before changing it.
#   renovate-local.sh [--refresh] [<root>]        report what is behind (default)
#   renovate-local.sh --apply [--dry-run] <root>  move gitlinks AND edit manifests
#   renovate-local.sh --managers <csv> <root>     default: whatever the tree HAS
#   renovate-local.sh --print-bin                 the resolved renovate.js
#   renovate-fleet.sh beside this one runs it over EVERY repo the family has

# Exit codes -- branch on THESE, never on the text. What each one promises about
# the tree: docs/dependency-updates.md#what-a-caller-branches-on
#   0  every reported update is now at its new value, or already was
#   1  the run could not complete. Nothing was written, or everything written --
#      manifests, lockfiles AND gitlinks -- was put back: the tree is as it was
#   2  the run completed and the tree is consistent, but at least one reported
#      update was NOT applied. A human applies those. Until 2026-09-10 this was
#      0, i.e. indistinguishable from a repo with nothing behind
#   130/143/129/141  SIGINT / SIGTERM / SIGHUP / SIGPIPE, undone first (on_signal)
set -uo pipefail

# 2 is the family's "the tool could not do its job" (docs/code-quality-tooling.md,
# "Exit 2 is never a pass"). EXIT_CODE is what the last line of this file exits
# with; only report_refusals() raises it, and err() bypasses it with 1.
EXIT_REFUSED=2
EXIT_CODE=0

# err/note/note_listing/refuse_listing. Sourced FIRST, before anything that can
# fail, because everything below reports through them. The argument is the name
# a fatal message is signed with.
# shellcheck source=renovate-say.sh
. "$(dirname "${BASH_SOURCE[0]}")/renovate-say.sh" renovate-local.sh \
  || { printf 'renovate-local.sh: cannot load renovate-say.sh beside me\n' >&2; exit 1; }

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
MANAGERS=""            # empty means: detect from the tree (see detect_managers)
MGR_DEFAULT_OFF=""
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
    -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)          err "unknown option: $1" ;;
    *)           [ -z "${TARGET}" ] || err "more than one repo root given"; TARGET="$1" ;;
  esac
  shift
done

TARGET="${TARGET:-$PWD}"
[ -d "${TARGET}" ] || err "not a directory: ${TARGET}"
TARGET="$(cd "${TARGET}" && pwd)"
git -C "${TARGET}" rev-parse --git-dir >/dev/null 2>&1 || err "not a git repo: ${TARGET}"

# Two inputs let the apply half run without a network round trip:
#   RENOVATE_LOCAL_REPORT - a report JSON to read INSTEAD of running Renovate
#   RENOVATE_LOCAL_CONFIG - a RESOLVED Renovate config (managerFilePatterns for
#                           detection, packageRules for the refusals)
# The test suite drives exactly these, and so can a human re-running --apply over
# a report they already have. With a report injected nothing is bootstrapped,
# because nothing would run.
INJECTED_REPORT="${RENOVATE_LOCAL_REPORT:-}"
INJECTED_CONFIG="${RENOVATE_LOCAL_CONFIG:-}"

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
NODE_BIN=""

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

if [ -z "${INJECTED_REPORT}" ] || [ "${MODE}" = print-bin ]; then
  bootstrap_node
  bootstrap_renovate
fi

if [ "${MODE}" = print-bin ]; then
  printf '%s\n' "${RENOVATE_JS}"
  exit 0
fi

# --------------------------------------------------------------------------
# The planner (renovate_planner.py) and the locator beside it
# (renovate_locator.py). Everything that READS the report JSON, MATCHES a
# packageRule or DECIDES which line carries a value lives there, so the plan a
# --dry-run prints and the edit an --apply writes come from one piece of code
# and cannot disagree.
# --------------------------------------------------------------------------
PLANNER="${HUB_ROOT}/linux/scripts/renovate_planner.py"
LOCATOR="${HUB_ROOT}/linux/scripts/renovate_locator.py"
[ -f "${PLANNER}" ] || err "the planner is missing at ${PLANNER}"
[ -f "${LOCATOR}" ] || err "the locator is missing at ${LOCATOR}"

rl_py() { "${PY_BIN}" "${PLANNER}" "$@"; }

# The lockfile half: which lock a manifest has, the tool that owns it, and the
# copy-aside that makes the manifest half one unit. Sourced AFTER note()/err()/
# refuse_listing(), which it calls.
LOCKS="${HUB_ROOT}/linux/scripts/renovate-locks.sh"
[ -f "${LOCKS}" ] || err "the lockfile half is missing at ${LOCKS}"
# shellcheck source=renovate-locks.sh
. "${LOCKS}"

# The tree half: which git owns this checkout, whether the paths this run writes
# are clean, and what ELSE moved while an ecosystem tool ran. Sourced AFTER the
# lockfile half, whose undo_run() the collateral refusal calls.
TREE="${HUB_ROOT}/linux/scripts/renovate-tree.sh"
[ -f "${TREE}" ] || err "the tree half is missing at ${TREE}"
# shellcheck source=renovate-tree.sh
. "${TREE}"

# --------------------------------------------------------------------------
# Manager selection. The default is every manager whose OWN file patterns match
# something this tree tracks -- because "git-submodules only" answered a question
# nobody asked once cargo, pub and npm needed applying too.
# --------------------------------------------------------------------------
MGR_CFG=""
RUN_DIR=""
# One scratch directory per run, and deliberately NOT mktemp's, because both
# files this script hands Renovate are fussy about their names:
#   * LOG_FILE is read through logger/utils.js `getEnv`, which does
#     `v?.toLowerCase().trim()` on the VALUE -- a mktemp name (tmp.AbCdEfGhIj)
#     is opened LOWERCASED, so the log lands in a file nobody reads and the
#     --print-config record silently goes missing.
#   * RENOVATE_CONFIG_FILE must carry a known EXTENSION; a mktemp name with none
#     kills the run outright with "FATAL: Unsupported file type".
# Both measured on 44.71.0, 2026-09-09. Hence: lowercase, checked, with suffixes.
run_scratch() {
  local lower
  [ -n "${RUN_DIR}" ] && return 0
  RUN_DIR="${CACHE_ROOT}/run-$$"
  lower="$(printf '%s' "${RUN_DIR}" | tr '[:upper:]' '[:lower:]')"
  [ "${RUN_DIR}" = "${lower}" ] \
    || err "scratch path ${RUN_DIR} has uppercase in it; Renovate lowercases LOG_FILE and would write to ${lower}. Point RENOVATE_LOCAL_CACHE at an all-lowercase directory."
  rm -rf "${RUN_DIR:?}"
  mkdir -p "${RUN_DIR}" || err "cannot create ${RUN_DIR}"
}

# Renovate's per-manager defaults (file patterns, and which managers ship
# disabled) depend on the Renovate VERSION, not on the repo, so probe them once
# from an empty throwaway checkout and cache them per version. Measured cost of
# the probe: 1.8s, no network beyond preset resolution an empty tree never asks
# for.
probe_manager_config() {
  MGR_CFG="${INJECTED_CONFIG}"
  [ -n "${MGR_CFG}" ] && return 0
  MGR_CFG="${CACHE_ROOT}/renovate-managers-${RENOVATE_VERSION}.json"
  [ -s "${MGR_CFG}" ] && return 0
  [ -n "${NODE_BIN}" ] || err "manager detection needs Renovate; pass --managers <csv> or RENOVATE_LOCAL_CONFIG"
  local tmp log
  run_scratch
  tmp="$(mktemp -d)" || err "mktemp failed"
  log="${RUN_DIR}/probe.ndjson"
  ( cd "${tmp}" && git init -q . \
    && RENOVATE_BASE_DIR="${CACHE_ROOT}/base" LOG_LEVEL=warn \
       RENOVATE_LOG_FILE="${log}" RENOVATE_LOG_FILE_LEVEL=info \
       RENOVATE_ONBOARDING=false RENOVATE_REQUIRE_CONFIG=optional \
       "${NODE_BIN}" "${RENOVATE_JS}" --platform=local --print-config \
         --enabled-managers=git-submodules >/dev/null 2>&1 )
  mkdir -p "${CACHE_ROOT}"
  rl_py config "${log}" > "${MGR_CFG}" || { rm -f "${MGR_CFG}"; err "could not read Renovate's manager defaults"; }
  rm -rf "${tmp}" "${log}"
}

detect_managers() {
  if [ -n "${MANAGERS}" ]; then
    note "managers: ${MANAGERS} -- explicit --managers, tree detection skipped."
    return 0
  fi
  probe_manager_config
  local list mgr en file csv=""
  local -a why=()
  list="$(mktemp)" || err "mktemp failed"
  MGR_TSV="$(mktemp)" || err "mktemp failed"
  git -C "${TARGET}" ls-files > "${list}" || err "git ls-files failed in ${TARGET}"
  # A FILE, not `< <(...)`: a process substitution's exit status is invisible to
  # the loop reading it, so a planner that DIED on a malformed config produced
  # zero rows -- and the emptiness guard below then blamed the tree
  # ("no manager's file patterns match anything tracked") instead of the config.
  if ! rl_py managers "${MGR_CFG}" "${list}" > "${MGR_TSV}"; then
    rm -f "${list}"
    err "could not read the manager file patterns out of ${MGR_CFG} (above)"
  fi
  while IFS=$'\t' read -r mgr en file; do
    [ -n "${mgr}" ] || continue
    csv="${csv:+${csv},}${mgr}"
    if [ "${en}" = false ]; then
      why+=("${mgr}  <- ${file}  (ships DISABLED in Renovate; enabled for this run)")
      MGR_DEFAULT_OFF="${MGR_DEFAULT_OFF:+${MGR_DEFAULT_OFF},}${mgr}"
    else
      why+=("${mgr}  <- ${file}")
    fi
  done < "${MGR_TSV}"
  rm -f "${list}" "${MGR_TSV}"
  [ -n "${csv}" ] || err "no Renovate manager's file patterns match anything tracked in ${TARGET}"
  MANAGERS="${csv}"
  note "managers selected from what this tree HAS (override with --managers <csv>):"
  printf '  %s\n' "${why[@]}"
  note "custom managers (custom.regex) are NOT auto-detected -- name them explicitly."
}

# A manager Renovate ships disabled is enabled from the GLOBAL config layer, which
# is the WEAKEST one: a repo whose own renovate.json says {"pre-commit":
# {"enabled": false}} still wins. Measured on 44.71.0 -- --enabled-managers alone
# does NOT override a manager's own `enabled: false`, which is why every
# .pre-commit-config.yaml in this family was invisible until now.
GLOBAL_CFG=""
write_global_config() {
  run_scratch
  GLOBAL_CFG="${RUN_DIR}/global.json"
  local mgr sep=""
  local -a off=()
  # IFS=',' read -r -a, not ${x//,/ }: the pattern split is what the IFS-safety
  # gate exists to catch, because it also splits on the spaces inside a value.
  IFS=',' read -r -a off <<<"${MGR_DEFAULT_OFF}"
  printf '{' > "${GLOBAL_CFG}"
  for mgr in ${off[@]+"${off[@]}"}; do
    [ -n "${mgr}" ] || continue
    printf '%s"%s":{"enabled":true}' "${sep}" "${mgr}" >> "${GLOBAL_CFG}"
    sep=,
  done
  printf '}\n' >> "${GLOBAL_CFG}"
}

# --------------------------------------------------------------------------
# Report: what is behind, according to the repo's OWN renovate config.
#
# Renovate's console output does NOT name the pending updates at info level --
# they appear only inside a "packageFiles with updates" blob at debug. So this
# asks for the machine-readable report instead (RENOVATE_REPORT_TYPE=file) and
# renders it. --print-config rides along in the same run, because the refusals
# below need the config Renovate actually resolved, presets included.
# --------------------------------------------------------------------------
REPORT_JSON=""
RUN_LOG=""
REPO_CFG=""

run_renovate() {
  if [ -n "${INJECTED_REPORT}" ]; then
    REPORT_JSON="${INJECTED_REPORT}"
    [ -s "${REPORT_JSON}" ] || err "RENOVATE_LOCAL_REPORT names no readable report: ${REPORT_JSON}"
    note "reading the injected report ${REPORT_JSON} (Renovate not run)"
    return 0
  fi
  run_scratch
  REPORT_JSON="${RUN_DIR}/report.json"
  RUN_LOG="${RUN_DIR}/run.ndjson"
  # --refresh drops the lookup cache first. A cache written before a push reports
  # the OLD tip as "available", i.e. a downgrade presented as an update -- seen
  # on 2026-09-09 with 46b73e33 -> 1fef6f28, which is its own parent.
  if [ "${REFRESH}" -eq 1 ]; then
    note "dropping the lookup cache at ${CACHE_ROOT}/base"
    rm -rf "${CACHE_ROOT:?}/base"
  fi
  write_global_config
  # RENOVATE_BASE_DIR keeps Renovate's scratch out of the repo being graded.
  # A token is deliberately NOT required: the git-submodules manager uses the
  # git-refs datasource, i.e. anonymous `git ls-remote`, and ssh remotes are
  # rewritten to https automatically. Other datasources will say so themselves.
  ( cd "${TARGET}" \
    && RENOVATE_BASE_DIR="${CACHE_ROOT}/base" \
       LOG_LEVEL="${RENOVATE_LOG_LEVEL:-warn}" \
       RENOVATE_CONFIG_FILE="${GLOBAL_CFG}" \
       RENOVATE_LOG_FILE="${RUN_LOG}" \
       RENOVATE_LOG_FILE_LEVEL=info \
       RENOVATE_REPORT_TYPE=file \
       RENOVATE_REPORT_PATH="${REPORT_JSON}" \
       RENOVATE_ONBOARDING=false \
       RENOVATE_REQUIRE_CONFIG=optional \
       "${NODE_BIN}" "${RENOVATE_JS}" \
         --platform=local \
         --print-config \
         --enabled-managers="${MANAGERS}" ) \
    || err "renovate exited non-zero"
  [ -s "${REPORT_JSON}" ] || err "renovate wrote no report to ${REPORT_JSON}"
}

# The config Renovate RESOLVED for this repo -- `extends` already expanded, which
# platform=local does do (measured 2026-09-09 on 44.71.0: the shared preset's own
# git-submodules block is what makes the hub report gitlinks at all).
resolve_repo_config() {
  REPO_CFG="${INJECTED_CONFIG}"
  [ -n "${REPO_CFG}" ] && return 0
  [ -s "${RUN_LOG}" ] || err "no Renovate log to read the resolved config from"
  REPO_CFG="$(mktemp)" || err "mktemp failed"
  rl_py config "${RUN_LOG}" > "${REPO_CFG}" \
    || err "could not read the resolved config out of ${RUN_LOG}"
}

run_report() {
  local n=0 mgr file dep cur new
  ROWS_TSV="$(mktemp)" || err "mktemp failed"
  # The same `< <(...)` trap as detect_managers, and this is the DEFAULT mode
  # every consumer wrapper invokes: a truncated or wrong-shaped report made the
  # planner die, the loop saw zero rows, and the run printed "up to date" with
  # rc 0 -- a crash rendered as a green result.
  rl_py rows "${REPORT_JSON}" > "${ROWS_TSV}" \
    || err "could not read the report at ${REPORT_JSON} (above)"
  while IFS=$'\t' read -r mgr file dep cur new; do
    [ -n "${dep}" ] || continue
    if [ "${n}" -eq 0 ]; then
      printf '%-16s %-34s %-14s %s\n' 'MANAGER' 'DEPENDENCY' 'CURRENT' 'AVAILABLE'
    fi
    printf '%-16s %-34s %-14s %s\n' "${mgr}" "${dep}" "${cur}" "${new}"
    n=$((n + 1))
  done < "${ROWS_TSV}"
  if [ "${n}" -eq 0 ]; then
    note "up to date: nothing behind for manager(s) ${MANAGERS}"
  else
    note ""
    note "${n} update(s) available (manager(s): ${MANAGERS})"
  fi
}

# --------------------------------------------------------------------------
# Apply. Two halves that must not half-run: gitlinks move with git, every other
# ecosystem is one targeted line rewrite in the file the report named.
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

# The apply half hands lists between functions. Globals, because bash cannot
# return a list and a $() round-trip would re-run the classification.
APPLY_PATHS=(); APPLY_REFUSED=(); APPLY_UNMATCHED=()
APPLY_DIRTY=(); APPLY_EOL=()
GIT_BIN=git; GIT_TARGET=""
PLAN_TSV=""; PLAN_JSON=""; MGR_TSV=""; ROWS_TSV=""
PLAN_SUBMODULES=(); PLAN_EDITS=(); PLAN_REFUSE=(); PLAN_SKIP=(); PLAN_DONE=()
EDIT_FILES=(); EDIT_LINES=0

# One parse of the report into every list the apply half needs. The JSON plan it
# writes alongside is what actually gets applied, so --dry-run and --apply cannot
# disagree about a single character.
build_plan() {
  local kind mgr file dep cur new line detail before after key
  resolve_repo_config
  PLAN_TSV="$(mktemp)" || err "mktemp failed"
  PLAN_JSON="$(mktemp)" || err "mktemp failed"
  rl_py plan "${REPORT_JSON}" "${REPO_CFG}" "${TARGET}" "${PLAN_JSON}" > "${PLAN_TSV}" \
    || err "planning the updates failed"
  while IFS=$'\t' read -r kind mgr file dep cur new line detail before after; do
    case "${kind}" in
      SUBMODULE) PLAN_SUBMODULES+=("${dep}") ;;
      REFUSE) PLAN_REFUSE+=("${mgr}  ${file}  ${dep}  ${cur} -> ${new}  ${detail}") ;;
      SKIP)   PLAN_SKIP+=("${mgr}  ${file}  ${dep}  ${cur} -> ${new}  -- ${detail}") ;;
      DONE)   PLAN_DONE+=("${file}:${line}  ${dep} is already at ${new}") ;;
      EDIT)   plan_edit_row "${mgr}" "${file}" "${dep}" "${cur}" "${new}" \
                            "${line}" "${before}" "${after}" ;;
    esac
  done < "${PLAN_TSV}"
}

# One EDIT row, recorded three ways: as the reviewable before/after block, as the
# file that must be clean before anything is written, and as the lockfile job the
# edit creates.
plan_edit_row() {
  local mgr="$1" file="$2" dep="$3" cur="$4" new="$5" line="$6" before="$7" after="$8"
  local key
  PLAN_EDITS+=("${file}:${line}  ${dep}  ${cur} -> ${new}" "  - ${before}" "  + ${after}")
  EDIT_LINES=$((EDIT_LINES + 1))
  case " ${EDIT_FILES[*]-} " in *" ${file} "*) ;; *) EDIT_FILES+=("${file}") ;; esac
  # The declared value is part of the key because cargo's lock command needs it
  # to disambiguate a crate the lockfile holds twice (renovate-locks.sh,
  # cargo_spec).
  key="${mgr}|${file}|${dep}|${cur}"
  case " ${LOCK_JOBS[*]-} " in *" ${key} "*) ;; *) LOCK_JOBS+=("${key}") ;; esac
}

# Which submodules to move: BOTH behind (Renovate says so) AND declaring a branch
# (.gitmodules says so). Neither half is sufficient alone.
select_apply_targets() {
  local -a declared=() branchless=()
  local pth b d
  while IFS= read -r pth; do [ -n "${pth}" ] && declared+=("${pth}"); done < <(submodule_paths with-branch)
  while IFS= read -r pth; do [ -n "${pth}" ] && branchless+=("${pth}"); done < <(submodule_paths without-branch)

  APPLY_PATHS=(); APPLY_REFUSED=(); APPLY_UNMATCHED=()
  for b in ${PLAN_SUBMODULES[@]+"${PLAN_SUBMODULES[@]}"}; do
    for d in ${declared[@]+"${declared[@]}"}; do
      [ "${b}" = "${d}" ] && { APPLY_PATHS+=("${b}"); continue 2; }
    done
    for d in ${branchless[@]+"${branchless[@]}"}; do
      [ "${b}" = "${d}" ] && { APPLY_REFUSED+=("${b}"); continue 2; }
    done
    APPLY_UNMATCHED+=("${b}")
  done
}

# PRE-FLIGHT, learned the hard way on 2026-09-09: `git submodule update --remote`
# over several paths is NOT ATOMIC. It walks them in order, and one dirty submodule
# makes git abort THAT checkout while the ones already done stay moved -- a
# half-applied superproject with a non-zero exit. The manifest edits join the same
# pre-flight for the same reason: a half-edited repo is worse than an unedited one.
assert_targets_applyable() {
  refuse_listing "wrong git for this working tree" \
    "The REPORT half is safe from anywhere -- it only reads. Run --apply with the
git that owns the working tree (on Windows: Git Bash or PowerShell)." \
    "REFUSING to apply: this git disagrees with the checkout about line endings." \
    "Every text file in the path(s) below differs by CR only, which means" \
    "the tree was written by a DIFFERENT git (the classic case: a Windows" \
    "checkout with core.autocrlf=true, read from WSL without git.exe on PATH):" \
    -- ${APPLY_EOL[@]+"${APPLY_EOL[@]}"}
  refuse_listing "clean or stash them, then re-run" "" \
    "REFUSING to apply: these paths have local changes, and writing over them" \
    "would mix this run's edits into work that is already there:" \
    -- ${APPLY_DIRTY[@]+"${APPLY_DIRTY[@]}"}
  # The planner's own pre-flight over the SAME plan the apply half would write:
  # every target contained in this checkout, unmoved since the plan, and
  # writable -- file and directory both. It runs HERE, which is before the
  # --dry-run branch, so a plan that cannot fully apply is refused rather than
  # printed as clean and then half-written.
  rl_py verify "${TARGET}" "${PLAN_JSON}" \
    || err "the planned edits cannot all be written (above); nothing was written"
  assert_locks_runnable
}

print_plan_notes() {
  note_listing \
    "REFUSED - the repo's own Renovate config sends these to a human" \
    "(dependencyDashboardApproval), so --apply will not write them:" \
    -- ${PLAN_REFUSE[@]+"${PLAN_REFUSE[@]}"} || true
  note_listing \
    "NOT APPLIED - the report named these, but placing the value would have" \
    "been a guess: either the locator would not read the line, or a real" \
    "parser will not sanction the edit. The reason is exact; by hand, then:" \
    -- ${PLAN_SKIP[@]+"${PLAN_SKIP[@]}"} || true
  note_listing \
    "already applied - the dependency's own line is at the new value:" \
    -- ${PLAN_DONE[@]+"${PLAN_DONE[@]}"} || true
  note_listing \
    "behind, and reported as a submodule that this repo does not declare --" \
    "--apply does not touch these:" \
    -- ${APPLY_UNMATCHED[@]+"${APPLY_UNMATCHED[@]}"} || true
  if note_listing \
      "REFUSED - behind, but no \`branch =\` in .gitmodules. A bare --remote would" \
      "walk these to the remote's DEFAULT branch, which is not the line the pin" \
      "was taken from (the FUZZTEST case):" \
      -- ${APPLY_REFUSED[@]+"${APPLY_REFUSED[@]}"}; then
    note "Move one of these by hand, deliberately, or give it a branch entry."
  fi
}

print_dry_run() {
  LOCK_PLANNED=()
  for_each_lock lock_planned_one
  note ""
  note "--dry-run: the exact writes this would make, and nothing else -- the"
  note "audit that runs AFTER a write has already been run over this text."
  note_listing "gitlink(s), moved to the tip of the branch .gitmodules names:" \
    -- ${APPLY_PATHS[@]+"${APPLY_PATHS[@]}"} || true
  note_listing "file edit(s) -- <file>:<line>, then that line before and after:" \
    -- ${PLAN_EDITS[@]+"${PLAN_EDITS[@]}"} || true
  note_listing "lockfile(s) that would then be refreshed:" \
    -- ${LOCK_PLANNED[@]+"${LOCK_PLANNED[@]}"} || true
  if [ "${#APPLY_PATHS[@]}" -gt 0 ]; then
    note ""
    note "the submodule command that would run:"
    note "  ${GIT_BIN} -C ${GIT_TARGET} submodule update --remote -- ${APPLY_PATHS[*]}"
  fi
}

# The gitlink half. `--remote` over several paths is NOT atomic -- it walks them
# in order and one failure leaves the earlier ones moved -- so its failure takes
# the SAME undo the manifest half takes, which is why snapshot_gitlinks recorded
# where each one was. The old message here told the human to sort it out with
# `git submodule update --init`; a tool that knows what it moved should move it
# back itself.
apply_submodules() {
  [ "${#APPLY_PATHS[@]}" -gt 0 ] || return 0
  note ""
  note "updating ${#APPLY_PATHS[@]} submodule(s) to the tip of the branch they name:"
  printf '  %s\n' "${APPLY_PATHS[@]}"
  # Explicit paths, and NO --recursive. Both deliberate; see the header.
  "${GIT_BIN}" -C "${GIT_TARGET}" submodule update --remote -- "${APPLY_PATHS[@]}" \
    || undo_run "git submodule update --remote failed"
  "${GIT_BIN}" -C "${GIT_TARGET}" submodule summary -- "${APPLY_PATHS[@]}" 2>/dev/null || true
}

# The manifest half. Every line it writes was located by the manager's OWN
# syntax and re-checked against the file before the first byte, and every file
# it is about to write was copied aside by run_apply's snapshot -- so a lock
# tool that fails puts all of them back, gitlinks included.
# docs/dependency-updates.md#all-of-it-or-none-of-it
apply_files() {
  [ "${EDIT_LINES}" -gt 0 ] || return 0
  note ""
  note "rewriting one value on ${EDIT_LINES} line(s) across ${#EDIT_FILES[@]} file(s):"
  if ! rl_py edit "${TARGET}" "${PLAN_JSON}"; then
    undo_run "the planned edits were not written"
  fi
  # The audit inside `rl_py edit` has just proven one value moved per file. The
  # lock tools run next, in the manifest's own directory, and several of them
  # rewrite the manifest they are handed -- so the proven bytes are hashed HERE,
  # between the proof and the tools, and checked again once they are done.
  manifest_record_shas ${EDIT_FILES[@]+"${EDIT_FILES[@]}"}
  refresh_locks
  if [ -n "${LOCK_FAILED}" ]; then
    undo_run "${LOCK_FAILED}"
  fi
  assert_manifests_unchanged
  assert_locks_sane
}

# The last thing an --apply prints, and the only place EXIT_CODE becomes 2.
#
# Four lists, one number: the repo's own config sent one to a human, the locator
# or the parser would not place one, a submodule declares no branch, a submodule
# is not declared here at all. They are four different reasons and one FACT --
# the report named an update and this run did not write it -- and a caller can
# only branch on the fact. It runs on the --dry-run path too, so a reviewer's
# exit code is the one the real run will give them.
report_refusals() {
  local n
  n=$(( ${#PLAN_REFUSE[@]} + ${#PLAN_SKIP[@]} \
        + ${#APPLY_REFUSED[@]} + ${#APPLY_UNMATCHED[@]} ))
  [ "${n}" -gt 0 ] || return 0
  EXIT_CODE="${EXIT_REFUSED}"
  note ""
  note "NOT EVERYTHING WAS APPLIED: ${n} reported update(s) are listed above as"
  note "REFUSED / NOT APPLIED / behind-but-not-eligible, and this run did not"
  note "write them. Exiting ${EXIT_REFUSED} -- rc 0 from --apply means every"
  note "reported update is at its new value, and nothing else does."
}

run_apply() {
  build_plan
  select_apply_targets
  print_plan_notes

  if [ "${#APPLY_PATHS[@]}" -eq 0 ] && [ "${EDIT_LINES}" -eq 0 ]; then
    note ""
    note "nothing to apply"
    report_refusals
    return 0
  fi

  select_git_for_tree
  assert_targets_applyable

  # --dry-run stops HERE, after the pre-flight and never before it: the value of a
  # plan is that it ran the checks that would block the real thing.
  if [ "${DRY_RUN}" -eq 1 ]; then
    print_dry_run
    report_refusals
    return 0
  fi

  # ONE snapshot over BOTH halves, before either writes. apply_files used to
  # take its own and SETTLE -- discarding them -- the line before the gitlink
  # half began, so a failing `submodule update` exited 1 with the manifests
  # written and the only copies gone, under an rc 1 documented as "the tree is
  # where it started". Measured 2026-09-10.
  # How the whole checkout stands, before anything at all -- the other half of
  # "all of it or none of it": the copies below say what this run may put back,
  # and this says what it may have MOVED. Taken first so nothing, not even the
  # in-flight marker, can be mistaken for a write an ecosystem tool made.
  tree_snapshot
  snapshot_targets ${EDIT_FILES[@]+"${EDIT_FILES[@]}"}
  # Manifests + their locks FIRST, then the gitlinks. Either failing puts BOTH
  # halves back, so the order is now about reviewability rather than safety.
  apply_files
  apply_submodules
  # Both halves are done. Before the tree becomes the copy worth keeping, the
  # one question the per-file audit cannot answer: did anything ELSE move?
  # docs/dependency-updates.md#nothing-else-in-the-repo-moved
  assert_no_collateral
  # Only NOW is the tree the copy worth keeping: this is what lets cleanup()
  # drop the copies and takes the in-flight marker off.
  settle_targets
  note ""
  note "Nothing is staged or committed. Stage the paths you reviewed."
  report_refusals
}

# --------------------------------------------------------------------------
# Leaving: on purpose, or because somebody stopped us
# --------------------------------------------------------------------------
# The undo a signal runs, and the rule that decides whether the copies beside
# the run may be deleted, both live in the lockfile half beside the copies
# themselves: on_signal() and discard_backups().
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP
# SIGPIPE is the signal a human actually sends, and it was the one not caught:
# `--apply ... | head -n 9`, or `| less` and then q. Measured at three cut
# points -- the deepest left the manifest at its new value with the lockfile
# never refreshed, and the caller read head's rc rather than this script's.
trap 'on_signal PIPE 141' PIPE

cleanup() {
  local f
  # PLANNER and LOCATOR are SHIPPED files, not temp ones -- they must never
  # appear here, and neither may an INJECTED report or config: those belong to
  # the caller.
  # Every mktemp this run takes, including TREE_BEFORE_IGNORED, which arrived
  # with the ignored-path comparison and was missed here: the suites that assert
  # a settled run leaves TMPDIR EMPTY caught it in seven places at once, which is
  # what that assertion is for.
  for f in "${PLAN_TSV}" "${PLAN_JSON}" "${MGR_TSV}" "${ROWS_TSV}" \
           "${TREE_BEFORE}" "${TREE_BEFORE_PATHS}" "${TREE_BEFORE_HASH}" \
           "${TREE_BEFORE_IGNORED}"; do
    if [ -n "${f}" ]; then rm -f "${f}"; fi
  done
  if [ -n "${REPO_CFG}" ] && [ -z "${INJECTED_CONFIG}" ]; then rm -f "${REPO_CFG}"; fi
  discard_backups
  # The scratch dir holds this run's report, its log and the global config; it is
  # ours, named after this PID, and created by run_scratch alone.
  if [ -n "${RUN_DIR}" ]; then rm -rf "${RUN_DIR:?}"; fi
  return 0
}
trap cleanup EXIT

# Before this run reads a single thing about the tree: did an earlier --apply
# die without finishing or undoing itself? A SIGKILL cannot be trapped, so that
# tree may be half-applied, and the next run used to exit 0 over it.
assert_no_wreckage
detect_managers
run_renovate
case "${MODE}" in
  report) run_report ;;
  apply)  run_report; run_apply ;;
  *)      err "unreachable mode ${MODE}" ;;
esac
# Explicit, because the status of the last command in that case is not a
# contract anybody should have to derive.
exit "${EXIT_CODE}"
