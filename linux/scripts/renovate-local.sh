#!/usr/bin/env bash
# renovate-local.sh - Renovate as a local CLI: Renovate detects what is behind,
# this script applies it, for every ecosystem the repo has.
# Before changing it, read docs/dependency-updates.md#before-you-change-the-script
# Usage:
#   renovate-local.sh [--refresh] [<root>]        report what is behind (default)
#   renovate-local.sh --apply [--dry-run] <root>  move gitlinks AND edit manifests
#   renovate-local.sh --managers <csv> <root>     default: whatever the tree HAS
#   renovate-local.sh --print-bin                 the resolved renovate.js
#   renovate-fleet.sh beside this one runs it over EVERY repo the family has

# Exit codes -- branch on these, never on the text:
#   0  every reported update is now at its new value, or already was
#   1  the run could not complete; anything written (manifests, lockfiles,
#      gitlinks) was put back, so the tree is as it was
#   2  the run completed and the tree is consistent, but at least one reported
#      update was NOT applied; a human applies those
#   130/143/129/141  SIGINT / SIGTERM / SIGHUP / SIGPIPE, undone first (on_signal)
# What each code promises about the tree:
# docs/dependency-updates.md#what-a-caller-branches-on
set -uo pipefail

# Only report_refusals() raises EXIT_CODE to 2; err() exits 1 directly.
EXIT_REFUSED=2
EXIT_CODE=0

# Sourced first, since everything below reports through it; the argument signs fatal messages.
# shellcheck source=renovate-say.sh
. "$(dirname "${BASH_SOURCE[0]}")/renovate-say.sh" renovate-local.sh \
  || { printf 'renovate-local.sh: cannot load renovate-say.sh beside me\n' >&2; exit 1; }

HUB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Parsed, never sourced: the Node and Renovate pins sit in tool-pins.env, which no image build reads.
# shellcheck source=01-core/load-versions-env.sh disable=SC1091
. "${HUB_ROOT}/linux/scripts/01-core/load-versions-env.sh" 2>/dev/null \
  && [ -f "${HUB_ROOT}/linux/scripts/01-core/tool-pins.env" ] \
  && load_versions_env "${HUB_ROOT}/linux/scripts/01-core/tool-pins.env" \
  || err "cannot read the version pins at linux/scripts/01-core/tool-pins.env"

# shellcheck source=01-core/platform.sh disable=SC1091
. "${HUB_ROOT}/linux/scripts/01-core/platform.sh" 2>/dev/null \
  || err "cannot load 01-core/platform.sh (needed for arch_normalize)"

: "${RENOVATE_NODE_VERSION:?RENOVATE_NODE_VERSION missing from tool-pins.env}"
: "${RENOVATE_VERSION:?RENOVATE_VERSION missing from tool-pins.env}"

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

# A saved report JSON and resolved config let --apply run offline, with nothing bootstrapped.
INJECTED_REPORT="${RENOVATE_LOCAL_REPORT:-}"
INJECTED_CONFIG="${RENOVATE_LOCAL_CONFIG:-}"

# Bootstrap pinned tools; probe python, since on Windows `python3` can be the Microsoft Store stub.
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

# arch_normalize owns the arch spelling; a local `uname -m` case is what the dupes gate flags.
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
  local path_node
  path_node="$(command -v node || true)"
  # Match the pinned major, not exceed it: Renovate's engines.node is a caret range.
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
  # A user-owned prefix: no sudo, nothing global touched.
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

# Reading the report and placing values live in the planner, so --dry-run and --apply cannot disagree.
PLANNER="${HUB_ROOT}/linux/scripts/renovate_planner.py"
LOCATOR="${HUB_ROOT}/linux/scripts/renovate_locator.py"
[ -f "${PLANNER}" ] || err "the planner is missing at ${PLANNER}"
[ -f "${LOCATOR}" ] || err "the locator is missing at ${LOCATOR}"

rl_py() { "${PY_BIN}" "${PLANNER}" "$@"; }

# The lockfile half; sourced after note()/err()/refuse_listing(), which it calls.
LOCKS="${HUB_ROOT}/linux/scripts/renovate-locks.sh"
[ -f "${LOCKS}" ] || err "the lockfile half is missing at ${LOCKS}"
# shellcheck source=renovate-locks.sh
. "${LOCKS}"

# The tree half; sourced after the lockfile half, whose undo_run() it calls.
TREE="${HUB_ROOT}/linux/scripts/renovate-tree.sh"
[ -f "${TREE}" ] || err "the tree half is missing at ${TREE}"
# shellcheck source=renovate-tree.sh
. "${TREE}"

# Manager selection: by default every manager whose own file patterns match a tracked file.
MGR_CFG=""
RUN_DIR=""
# Not mktemp: Renovate lowercases the LOG_FILE value and rejects a config file with no extension.
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

# Manager defaults depend on the Renovate version, not the repo: probe an empty checkout once per version.
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
  # A file, not `< <(...)`, whose exit status the loop cannot see: a dead planner would read as zero rows.
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

# --enabled-managers alone does not undo a shipped `enabled: false`; this global layer does, and a repo's own config still wins.
GLOBAL_CFG=""
write_global_config() {
  run_scratch
  GLOBAL_CFG="${RUN_DIR}/global.json"
  local mgr sep=""
  local -a off=()
  # Not ${x//,/ }: that also splits on spaces inside a value.
  IFS=',' read -r -a off <<<"${MGR_DEFAULT_OFF}"
  printf '{' > "${GLOBAL_CFG}"
  for mgr in ${off[@]+"${off[@]}"}; do
    [ -n "${mgr}" ] || continue
    printf '%s"%s":{"enabled":true}' "${sep}" "${mgr}" >> "${GLOBAL_CFG}"
    sep=,
  done
  printf '}\n' >> "${GLOBAL_CFG}"
}

# Report: the console names pending updates only at debug level, so read the file report instead.
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
  # A cache written before a push reports the old tip as an update, i.e. a downgrade.
  if [ "${REFRESH}" -eq 1 ]; then
    note "dropping the lookup cache at ${CACHE_ROOT}/base"
    rm -rf "${CACHE_ROOT:?}/base"
  fi
  write_global_config
  # No token needed: git-refs is anonymous `git ls-remote`; other datasources say so themselves.
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

# The resolved config, `extends` expanded: the shared preset is what enables git-submodules.
resolve_repo_config() {
  [ -n "${REPO_CFG}" ] && return 0
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
  # Same `< <(...)` trap as detect_managers: a dead planner must not print "up to date".
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
  report_skipped
}

# A skipped dep is never "behind", so without this list an unreadable pin (ROCm's 10.0 under semver) reads as up to date.
report_skipped() {
  local kind mgr file dep cur why k=0 design=""
  SKIP_TSV="$(mktemp)" || err "mktemp failed"
  rl_py skipped "${REPORT_JSON}" > "${SKIP_TSV}" \
    || err "could not read the skipped dependencies out of ${REPORT_JSON} (above)"
  while IFS=$'\t' read -r kind mgr file dep cur why; do
    case "${kind}" in
      SKIP)
        if [ "${k}" -eq 0 ]; then
          note ""
          note "NOT CHECKED - Renovate skipped these, so no update to them is ever reported:"
          printf '%-16s %-34s %-14s %s\n' 'MANAGER' 'DEPENDENCY' 'CURRENT' 'REASON'
        fi
        printf '%-16s %-34s %-14s %s  (%s)\n' "${mgr}" "${dep}" "${cur}" "${why}" "${file}"
        k=$((k + 1)) ;;
      DESIGN) design="${design:+${design}, }${mgr} ${file}" ;;
    esac
  done < "${SKIP_TSV}"
  if [ "${k}" -gt 0 ]; then
    note "${k} dependency(ies) not checked: fix the annotation or the value (docs/dependency-updates.md#a-skipped-pin-is-not-up-to-date)"
  fi
  if [ -n "${design}" ]; then note "skipped by design (nothing to look up): ${design}"; fi
  return 0
}

# Renovate builds lockFileMaintenance and never reports it under --platform=local. See docs/dependency-updates.md#lock-file-maintenance
MAINT_TSV=""; MAINT_JOBS=(); MAINT_ROWS=(); MAINT_SKIP=(); MAINT_SEEN=()
plan_lock_maintenance() {
  local mgr file amb
  local -a saved=(${LOCK_JOBS[@]+"${LOCK_JOBS[@]}"})
  # An injected report without a config (the offline report) has no setting to read.
  [ -n "${INJECTED_CONFIG}" ] || [ -s "${RUN_LOG}" ] || return 0
  resolve_repo_config
  MAINT_TSV="$(mktemp)" || err "mktemp failed"
  rl_py lockmaint "${REPORT_JSON}" "${REPO_CFG}" > "${MAINT_TSV}" \
    || err "could not read lockFileMaintenance out of the resolved config (above)"
  # The same walk as every lock job, over candidate jobs; run_apply appends the kept ones.
  LOCK_JOBS=()
  while IFS=$'\t' read -r mgr file; do
    if [ -n "${file}" ]; then LOCK_JOBS+=("${mgr}|${file}|${LOCK_ALL}|${LOCK_ALL}"); fi
  done < "${MAINT_TSV}"
  for_each_lock maint_plan_one
  for amb in ${LOCK_AMBIGUOUS[@]+"${LOCK_AMBIGUOUS[@]}"}; do
    MAINT_SKIP+=("${amb}, so which tool owns it is not knowable")
  done
  LOCK_JOBS=(${saved[@]+"${saved[@]}"})
}

# The for_each_lock callback: one job per lock, since workspace members share the root lock.
maint_plan_one() {
  local cmd behind=""
  rl_has "$4" ${MAINT_SEEN[@]+"${MAINT_SEEN[@]}"} && return 0
  MAINT_SEEN+=("$4")
  cmd="$(maint_argv "$1" | tr '\n' ' ')"
  if [ -z "${cmd}" ]; then
    MAINT_SKIP+=("$4  ($1: no lock file maintenance command known here; refresh it by hand)")
    return 0
  fi
  MAINT_JOBS+=("${LOCK_JOB_NOW}")
  # Report only: --apply runs the upgrade itself, and a dry run there would only slow it.
  if [ "${MODE}" = report ]; then
    behind="  ($(maint_behind "$1" "${TARGET}/$3" "${4##*/}"))"
  fi
  MAINT_ROWS+=("$(printf '%-34s %s%s' "$4" "${cmd% }" "${behind}")")
}

report_lock_maintenance() {
  plan_lock_maintenance
  if [ "${#MAINT_ROWS[@]}" -gt 0 ]; then
    note ""
    note "LOCK FILE MAINTENANCE - on in the resolved config. Renovate never reports"
    note "it here, so no row above shows how far these locks are behind; the count"
    note "is each tool's own dry run, which writes no lock. --apply moves every"
    note "entry to the newest release its manifest allows:"
    printf '  %s\n' "${MAINT_ROWS[@]}"
  fi
  note_listing "NOT CARRIED - under lock file maintenance, but with no command here:" \
    -- ${MAINT_SKIP[@]+"${MAINT_SKIP[@]}"} || true
}

# Apply: gitlinks move with git, other ecosystems by one line rewrite; neither half may half-run.
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

# Globals: bash cannot return a list, and a $() round-trip would re-run the classification.
APPLY_PATHS=(); APPLY_REFUSED=(); APPLY_UNMATCHED=()
APPLY_DIRTY=(); APPLY_EOL=()
GIT_BIN=git; GIT_TARGET=""
PLAN_TSV=""; PLAN_JSON=""; MGR_TSV=""; ROWS_TSV=""; SKIP_TSV=""
PLAN_SUBMODULES=(); PLAN_EDITS=(); PLAN_REFUSE=(); PLAN_SKIP=(); PLAN_DONE=()
EDIT_FILES=(); EDIT_LINES=0

# The JSON plan written here is what gets applied, so --dry-run and --apply cannot disagree.
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

# One EDIT row: a reviewable diff, a file that must be clean, and a lockfile job.
plan_edit_row() {
  local mgr="$1" file="$2" dep="$3" cur="$4" new="$5" line="$6" before="$7" after="$8"
  local key
  PLAN_EDITS+=("${file}:${line}  ${dep}  ${cur} -> ${new}" "  - ${before}" "  + ${after}")
  EDIT_LINES=$((EDIT_LINES + 1))
  case " ${EDIT_FILES[*]-} " in *" ${file} "*) ;; *) EDIT_FILES+=("${file}") ;; esac
  # The declared value disambiguates a crate the lockfile holds twice (renovate-locks.sh cargo_spec).
  key="${mgr}|${file}|${dep}|${cur}"
  case " ${LOCK_JOBS[*]-} " in *" ${key} "*) ;; *) LOCK_JOBS+=("${key}") ;; esac
}

# Move a submodule only when it is behind AND declares a branch; neither alone suffices.
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

# `submodule update --remote` is not atomic, so every target is checked before anything is written.
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
  # Before the --dry-run branch, so a plan that cannot fully apply is refused, not printed as clean.
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

# `--remote` is not atomic, so its failure takes the same undo as the manifest half.
apply_submodules() {
  [ "${#APPLY_PATHS[@]}" -gt 0 ] || return 0
  note ""
  note "updating ${#APPLY_PATHS[@]} submodule(s) to the tip of the branch they name:"
  printf '  %s\n' "${APPLY_PATHS[@]}"
  # Explicit paths and no --recursive: only the eligible gitlinks of this repo move.
  "${GIT_BIN}" -C "${GIT_TARGET}" submodule update --remote -- "${APPLY_PATHS[@]}" \
    || undo_run "git submodule update --remote failed"
  "${GIT_BIN}" -C "${GIT_TARGET}" submodule summary -- "${APPLY_PATHS[@]}" 2>/dev/null || true
}

# Every target was copied aside first, so a failing lock tool puts all back. See docs/dependency-updates.md#all-of-it-or-none-of-it
apply_files() {
  [ "${#LOCK_JOBS[@]}" -gt 0 ] || [ "${EDIT_LINES}" -gt 0 ] || return 0
  if [ "${EDIT_LINES}" -gt 0 ]; then
    note ""
    note "rewriting one value on ${EDIT_LINES} line(s) across ${#EDIT_FILES[@]} file(s):"
    if ! rl_py edit "${TARGET}" "${PLAN_JSON}"; then
      undo_run "the planned edits were not written"
    fi
  fi
  # Lock tools may rewrite the manifest, so hash the audited bytes now and re-check after them.
  manifest_record_shas ${EDIT_FILES[@]+"${EDIT_FILES[@]}"}
  refresh_locks
  if [ -n "${LOCK_FAILED}" ]; then
    undo_run "${LOCK_FAILED}"
  fi
  assert_manifests_unchanged
  assert_locks_sane
}

# The only place EXIT_CODE becomes 2; --dry-run runs it too, so a reviewer sees the real rc.
report_refusals() {
  local n
  n=$(( ${#PLAN_REFUSE[@]} + ${#PLAN_SKIP[@]} \
        + ${#APPLY_REFUSED[@]} + ${#APPLY_UNMATCHED[@]} + ${#MAINT_SKIP[@]} ))
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
  # After the edits' jobs, so a maintained lock is refreshed last and ends at the newest it allows.
  LOCK_JOBS+=(${MAINT_JOBS[@]+"${MAINT_JOBS[@]}"})
  select_apply_targets
  print_plan_notes

  if [ "${#APPLY_PATHS[@]}" -eq 0 ] && [ "${#LOCK_JOBS[@]}" -eq 0 ] && [ "${EDIT_LINES}" -eq 0 ]; then
    note ""
    note "nothing to apply"
    report_refusals
    return 0
  fi

  select_git_for_tree
  assert_targets_applyable

  # --dry-run stops after the pre-flight: a plan's value is that it ran the blocking checks.
  if [ "${DRY_RUN}" -eq 1 ]; then
    print_dry_run
    report_refusals
    return 0
  fi

  # One snapshot over both halves, tree first, so not even the in-flight marker reads as a tool's write.
  tree_snapshot
  snapshot_targets ${EDIT_FILES[@]+"${EDIT_FILES[@]}"}
  # Either half failing restores both, so this order is for reviewability only.
  apply_files
  apply_submodules
  # See docs/dependency-updates.md#nothing-else-in-the-repo-moved
  assert_no_collateral
  # Only now is the tree worth keeping: cleanup() may drop the copies and the in-flight marker.
  settle_targets
  note ""
  note "Nothing is staged or committed. Stage the paths you reviewed."
  report_refusals
}

# Leaving: on_signal() and discard_backups() live in renovate-locks.sh, beside the copies.
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP
# SIGPIPE is the one a human sends (`| head`, `| less` then q); it can cut between manifest and lock.
trap 'on_signal PIPE 141' PIPE

cleanup() {
  local f
  # Every mktemp of this run; never PLANNER/LOCATOR or an injected report/config, which are not ours.
  for f in "${PLAN_TSV}" "${PLAN_JSON}" "${MGR_TSV}" "${ROWS_TSV}" "${SKIP_TSV}" "${MAINT_TSV}" \
           "${TREE_BEFORE}" "${TREE_BEFORE_PATHS}" "${TREE_BEFORE_HASH}" \
           "${TREE_BEFORE_IGNORED}"; do
    if [ -n "${f}" ]; then rm -f "${f}"; fi
  done
  if [ -n "${REPO_CFG}" ] && [ -z "${INJECTED_CONFIG}" ]; then rm -f "${REPO_CFG}"; fi
  discard_backups
  # The scratch dir is ours alone: named after this PID, created only by run_scratch.
  if [ -n "${RUN_DIR}" ]; then rm -rf "${RUN_DIR:?}"; fi
  return 0
}
trap cleanup EXIT

# A SIGKILLed earlier --apply may have left the tree half-applied; check before reading anything.
assert_no_wreckage
detect_managers
run_renovate
case "${MODE}" in
  report) run_report; report_lock_maintenance ;;
  apply)  run_report; report_lock_maintenance; run_apply ;;
  *)      err "unreachable mode ${MODE}" ;;
esac
# Explicit: the status of that case's last command is no contract.
exit "${EXIT_CODE}"
