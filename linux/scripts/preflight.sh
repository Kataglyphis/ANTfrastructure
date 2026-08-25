#!/usr/bin/env bash
# preflight.sh — run every FAST (no-build) verification before a cross rebuild.
#
# The base->:latest-cross rebuild takes hours under QEMU. Whole classes of error
# (see docs/cross-build-verification.md) can be caught in seconds/minutes here
# instead. Run this before kicking off build-cross-chain.sh.
#
# Each check is independent; all run even if an earlier one fails, and the script
# exits non-zero if any failed (so CI/automation sees a single verdict).
#
# Usage: linux/scripts/preflight.sh
#
# Subset selection (so CI workflows and git hooks reuse THIS list instead of
# copy-pasting their own): each check has a stable slug, and
#   PREFLIGHT_ONLY=slug1,slug2   runs only the named checks
#   PREFLIGHT_SKIP=slug1,slug2   runs everything except the named checks
# Unset (the default) runs the full gate. Unknown slugs are an error so a
# renamed check cannot silently drop out of a caller's subset.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
FAILED=()
RAN_CHECKS=0

# Interpreter for the Python-based checks. Explicit override always wins:
#   PREFLIGHT_PYTHON="uv run --no-project python" bash linux/scripts/preflight.sh
#
# Without one, plain `python3` is NOT trusted on sight. On Windows hosts under
# Git Bash it is usually the Microsoft Store stub, which prints an install hint
# and exits non-zero — so the Python-based checks fail for a reason that has
# nothing to do with the commit. That is not a theoretical concern: it is why
# the pre-commit hooks stayed unusable (and therefore disabled) on the primary
# dev clone until 2026-08-08, letting an unresolved merge conflict reach main.
#
# So: probe candidates and take the first that can actually RUN something. The
# stub fails `-c pass` in well under a second, so the cost is negligible.
if [ -z "${PREFLIGHT_PYTHON:-}" ]; then
  for _py in python3 python3.14 python3.13 python3.12 python "${HOME}/.local/bin/python3.14.exe"; do
    if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'pass' >/dev/null 2>&1; then
      PREFLIGHT_PYTHON="${_py}"
      break
    fi
  done
  unset _py
fi
if [ -z "${PREFLIGHT_PYTHON:-}" ]; then
  printf "${RED}✗${NC} no working Python found for the Python-based checks.\n" >&2
  printf "   Tried: python3, python3.14, python3.13, python3.12, python, ~/.local/bin/python3.14.exe\n" >&2
  printf "   Set PREFLIGHT_PYTHON to a real interpreter, e.g.\n" >&2
  printf "     PREFLIGHT_PYTHON=\"uv run --no-project python\"\n" >&2
  exit 1
fi
# The Python checks print ✓/✗; on Windows consoles the default cp1252 codec
# dies on those. Force UTF-8 mode (no-op on Linux).
export PYTHONUTF8=1

KNOWN_SLUGS=(crlf-guard shellcheck copy-coverage critical-fixes patch-integrity artifact-parity \
             arg-consistency version-snapshot mirror-consistency runtime-paths env-knobs \
             dockerfile-lint workflow-lint python-lint secret-scan android-parity script-tests stage-graph \
             doc-links)

_in_csv() {  # _in_csv needle csv
  local needle="$1" csv="$2" item
  local -a _items=()
  IFS=',' read -ra _items <<< "${csv}"
  for item in "${_items[@]}"; do [ "${item}" = "${needle}" ] && return 0; done
  return 1
}

for _sel in ${PREFLIGHT_ONLY:-} ${PREFLIGHT_SKIP:-}; do
  IFS=',' read -ra _slugs <<< "${_sel}"
  for _slug in "${_slugs[@]}"; do
    _known=1
    for _k in "${KNOWN_SLUGS[@]}"; do [ "${_k}" = "${_slug}" ] && _known=0; done
    if [ "${_known}" -ne 0 ]; then
      printf "${RED}Unknown preflight slug: %s${NC} (known: %s)\n" "${_slug}" "${KNOWN_SLUGS[*]}" >&2
      exit 2
    fi
  done
done

check_selected() {  # check_selected slug -> 0 if this check should run
  local slug="$1"
  if [ -n "${PREFLIGHT_ONLY:-}" ]; then _in_csv "${slug}" "${PREFLIGHT_ONLY}" && return 0 || return 1; fi
  if [ -n "${PREFLIGHT_SKIP:-}" ]; then _in_csv "${slug}" "${PREFLIGHT_SKIP}" && return 1 || return 0; fi
  return 0
}

run_check() {
  local slug="$1" name="$2"; shift 2
  check_selected "${slug}" || return 0
  RAN_CHECKS=$((RAN_CHECKS + 1))
  printf "\n${BOLD}== %s ==${NC}\n" "${name}"
  if "$@"; then
    printf "${GREEN}✓ %s${NC}\n" "${name}"
  else
    printf "${RED}✗ %s${NC}\n" "${name}"
    FAILED+=("${name}")
  fi
}

# 0. Working-tree CRLF guard: a *.sh that is LF in the index but CRLF in the
#    working tree (e.g. a checkout under core.autocrlf=true) breaks bash inside
#    the containers ("$'\r': command not found") long before any build runs.
check_crlf_guard() {
  local offenders
  # `|| echo FAIL...`: if git itself fails here (not a work tree, broken index)
  # the check must FAIL LOUDLY, not pass on an empty result.
  offenders="$(git ls-files --eol -- '*.sh' 2>/dev/null | awk -F'\t' '$1 ~ /w\/crlf/ {print $2}' \
    || echo "__git-ls-files-FAILED__")"
  if [ -n "${offenders}" ]; then
    printf 'CRLF working-tree line endings detected in tracked *.sh file(s):\n'
    printf '  %s\n' ${offenders}
    printf 'Fix (re-materialize LF from the index): rm <file> && git checkout -- <file>\n'
    return 1
  fi
  printf 'no w/crlf *.sh files in the working tree\n'
}
run_check crlf-guard "working-tree CRLF guard"    check_crlf_guard

# 1. Shell lint gate (shellcheck -S error across all scripts).
run_check shellcheck "shellcheck gate"            bash linux/scripts/lint-shell.sh

# 2. Every referenced /opt/scripts path is COPY'd/mounted into its image.
run_check copy-coverage "script COPY coverage"    ${PREFLIGHT_PYTHON} linux/scripts/verify-script-copy-coverage.py

# 3. Critical-fix source integrity (incl. fix6: native-GCC system paths, bugs D/E).
run_check critical-fixes "critical fixes"         bash linux/scripts/verify-critical-fixes.sh

# 3b. Patch files are well-formed unified diffs AND still referenced (no orphans).
run_check patch-integrity "patch integrity"       bash linux/scripts/verify-patch-integrity.sh

# 3c. Dockerfile.package artifact COPY lane: artifact-source stage exists and
#     src/dst paths stay canonical (undocumented relocations fail).
run_check artifact-parity "artifact copy parity"  bash linux/scripts/verify-artifact-copy-parity.sh

# 4. Dockerfile ARG names/values agree with versions.env + forwarding.
run_check arg-consistency "ARG consistency"       bash linux/scripts/01-core/verify-arg-consistency.sh

# 5. Version snapshots / inline markers / deps table are in sync.
# The [ -f ] guards FAIL (not skip) on a missing file: these are tracked repo
# files, so absence means a broken tree/rename — silently dropping the check
# would leave CI subsets (build-docs.yml runs PREFLIGHT_ONLY=version-snapshot,
# mirror-consistency) permanently green with the gate gone, and the
# zero-checks-ran guard only fires when NOTHING ran.
if [ -f docs/scripts/sync_versions.py ]; then
  run_check version-snapshot "version snapshot"   ${PREFLIGHT_PYTHON} docs/scripts/sync_versions.py --check
else
  run_check version-snapshot "version snapshot"   bash -c 'echo "docs/scripts/sync_versions.py MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# 5a. Docs cross-references: relative links, deep-link anchors, the `file.md § Heading`
# prose convention, and index coverage (docs/INDEX.md + the Sphinx toctree).
# The 2026-08-25 structural pass moved ~5,000 lines and rewrote ~50 references by
# hand; nothing kept that verified afterwards. Same [ -f ] FAIL-not-skip contract
# as the version-snapshot check below it — a renamed script must not silently
# leave build-docs.yml and stale-docs-check.yml green with the gate gone.
if [ -f docs/scripts/verify_doc_links.py ]; then
  run_check doc-links "docs cross-references"     ${PREFLIGHT_PYTHON} docs/scripts/verify_doc_links.py
else
  run_check doc-links "docs cross-references"     bash -c 'echo "docs/scripts/verify_doc_links.py MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# 5b. A1: env-knob registry — every consumed ${VAR:-} knob must have an owner
# (versions.env / Dockerfile ARG-ENV / script assignment / lint-env-knobs.allow).
# Advisory internally unless KNOB_GATE=1.
if [ -f linux/scripts/lint-env-knobs.sh ]; then
  run_check env-knobs "env-knob registry" bash linux/scripts/lint-env-knobs.sh
fi

# 6. Canonical Ubuntu mirror ARGs present across Dockerfiles.
if [ -f linux/scripts/01-core/verify-ubuntu-mirror-consistency.sh ]; then
  run_check mirror-consistency "ubuntu mirror consistency" bash linux/scripts/01-core/verify-ubuntu-mirror-consistency.sh
else
  run_check mirror-consistency "ubuntu mirror consistency" bash -c 'echo "verify-ubuntu-mirror-consistency.sh MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# 7. Runtime PATH/LD_LIBRARY_PATH/PKG_CONFIG_PATH match runtime-paths.env.
if [ -f linux/scripts/04-runtime/verify-runtime-paths.sh ]; then
  run_check runtime-paths "runtime path consistency" bash linux/scripts/04-runtime/verify-runtime-paths.sh
else
  run_check runtime-paths "runtime path consistency" bash -c 'echo "verify-runtime-paths.sh MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# 8. Dockerfile lint (hadolint, policy in .hadolint.yaml; bootstraps a pinned,
#    SHA-verified hadolint when none is on PATH).
run_check dockerfile-lint "dockerfile lint (hadolint)" bash linux/scripts/lint-dockerfiles.sh

# 9. Workflow/composite-action lint (actionlint, same bootstrap pattern).
run_check workflow-lint "workflow lint (actionlint)" bash linux/scripts/lint-workflows.sh

# Python gate (backlog C4): hard-fails only on real-error classes (syntax /
# undefined names); full ruleset is advisory — see lint-python.sh header.
run_check python-lint "python lint (ruff)" bash linux/scripts/lint-python.sh

# Secret scan (backlog SEC1): gitleaks over the working tree, ENFORCING —
# the initial 2026-08-10 scan was clean after triaging two public-trust-anchor
# false positives into .gitleaksignore (each entry needs a justification).
run_check secret-scan "secret scan (gitleaks)" bash linux/scripts/lint-secrets.sh

# 10. The five parallel Android library stages stay identical modulo ANDROID_LIB.
run_check android-parity "android stage parity" bash linux/scripts/01-core/verify-android-stage-parity.sh

# 11. Unit tests for the tag/build-arg/disk-guard logic in linux/scripts.
run_check script-tests "linux script unit tests" bash linux/scripts/tests/run-tests.sh

# 12. Stage-graph self-consistency (parent refs, dockerfiles, tags, cycles).
# Pure and sub-second — it used to run only at build kickoff
# (build-cross-chain.sh), so a malformed graph escaped this fast gate and was
# discovered by the orchestrator instead.
run_check stage-graph "cross stage graph validation" bash -c '
  source linux/scripts/01-core/modules.sh 2>/dev/null || true
  source linux/scripts/01-core/build-helpers.sh
  source linux/scripts/01-core/platform.sh
  source linux/scripts/01-core/tag-naming.sh
  source linux/scripts/01-core/stage-defs.sh
  IMAGE_REPO="${IMAGE_REPO:-preflight-check}" cross_stage_validate_graph'

# Informational only (backlog F7 residual): a locally-committed-but-unpushed
# submodule pointer breaks a downstream checkout/clone (e.g. build-docs.yml's
# DocumANTation checkout) LOUDLY, but only post-push. This is a warn-only
# CONTAINMENT probe: for each initialized submodule, is the recorded pointer
# actually REACHABLE on its remote (a ref tip, or an ancestor of one)? A pointer
# that is not reachable is almost certainly an unpushed local commit. This is
# strictly network-dependent, so it WARNs and NEVER fails, and is silent when
# offline / the remote is unreachable (empty ls-remote -> skip). It generalizes
# the earlier DocumANTation-only probe so future submodules are covered too.
_probe_submodule_pushed() {  # dir
  local dir="$1" recorded remote_tips tip
  [ -e "${dir}/.git" ] || return 0
  recorded="$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)"
  [ -n "${recorded}" ] || return 0
  # Remote ref tips (SHAs). Network-dependent; timeout-bounded. Empty result
  # (offline / no remote / auth failure) -> degrade silently, never warn.
  remote_tips="$(timeout 10 git -C "${dir}" ls-remote --heads --tags origin 2>/dev/null | awk '{print $1}' || true)"
  [ -n "${remote_tips}" ] || return 0
  # Exact tip match is the common, cheapest case.
  if printf '%s\n' "${remote_tips}" | grep -qxF "${recorded}"; then return 0; fi
  # Otherwise: reachable as an ancestor of any remote tip we can resolve locally?
  # (The submodule tree is checked out at the recorded SHA, so its objects are
  # present; remote tips we already have locally let us test ancestry offline-free.)
  for tip in ${remote_tips}; do
    if git -C "${dir}" cat-file -e "${tip}^{commit}" 2>/dev/null \
       && git -C "${dir}" merge-base --is-ancestor "${recorded}" "${tip}" 2>/dev/null; then
      return 0
    fi
  done
  printf "${YELLOW}NOTE:${NC} submodule %s pin %.9s is not reachable on its remote (unpushed local commit or upstream rewrite) — push it before a build/docs job that clones it.\n" \
    "${dir}" "${recorded}"
}
while IFS= read -r _sub_path; do
  [ -n "${_sub_path}" ] && _probe_submodule_pushed "${_sub_path}"
done < <(git config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
unset -f _probe_submodule_pushed 2>/dev/null || true

printf "\n${BOLD}=== preflight summary ===${NC}\n"
# Zero-checks-ran guard: a PREFLIGHT_ONLY/PREFLIGHT_SKIP combination that
# selects NOTHING would otherwise print "All preflight checks passed." with
# zero checks executed — a silent green no-op (the exact drop-out class the
# KNOWN_SLUGS validator guards against, but for the intersection case).
if [ "${RAN_CHECKS:-0}" -eq 0 ]; then
  printf "${RED}No preflight checks ran${NC} (PREFLIGHT_ONLY/PREFLIGHT_SKIP selected nothing) — refusing to report green.\n"
  exit 2
fi
if [ "${#FAILED[@]}" -eq 0 ]; then
  printf "${GREEN}All preflight checks passed.${NC} Safe to start the cross rebuild.\n"
  exit 0
fi
printf "${RED}%d check(s) failed:${NC}\n" "${#FAILED[@]}"
printf "${YELLOW}  - %s${NC}\n" "${FAILED[@]}"
printf "Fix these before a multi-hour rebuild.\n"
exit 1
