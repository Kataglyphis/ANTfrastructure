#!/usr/bin/env bash
# preflight.sh — fast no-build checks before a cross rebuild; PREFLIGHT_ONLY/PREFLIGHT_SKIP take slug lists.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
FAILED=()
RAN_CHECKS=0

# Probe with -c pass: on Git Bash, python3 can be the Microsoft Store stub.
if [ -z "${PREFLIGHT_PYTHON:-}" ]; then
  for _py in python3 python3.14 python3.13 python3.12 python "${HOME}/.local/bin/python3.14.exe"; do
    if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'pass' >/dev/null 2>&1; then
      PREFLIGHT_PYTHON="${_py}"
      break
    fi
  done
  unset _py
fi
export PREFLIGHT_PYTHON
if [ -z "${PREFLIGHT_PYTHON:-}" ]; then
  printf "${RED}✗${NC} no working Python found for the Python-based checks.\n" >&2
  printf "   Tried: python3, python3.14, python3.13, python3.12, python, ~/.local/bin/python3.14.exe\n" >&2
  printf "   Set PREFLIGHT_PYTHON to a real interpreter, e.g.\n" >&2
  printf "     PREFLIGHT_PYTHON=\"uv run --no-project python\"\n" >&2
  exit 1
fi
# Windows consoles' cp1252 codec cannot print the checks' ✓/✗.
export PYTHONUTF8=1

: "${PREFLIGHT_ONLY:=}"
: "${PREFLIGHT_SKIP:=}"

KNOWN_SLUGS=(crlf-guard shellcheck stdout-returns copy-coverage context-paths critical-fixes patch-integrity code-dupes artifact-parity \
             arg-consistency version-snapshot mirror-consistency runtime-paths env-knobs \
             dockerfile-lint workflow-lint python-lint secret-scan android-parity script-tests stage-graph \
             pkg-names \
             advert-keys \
             masked-decls \
             trailing-conditional \
             comment-size \
             code-size \
             code-complexity \
             dead-functions \
             shellcheck-warnings \
             mutations \
             gate-registry \
             shared-config \
             cmake-format \
             doc-links doc-dupes sbom)

_in_csv() {  # _in_csv needle csv
  local needle="$1" csv="$2" item
  local -a _items=()
  IFS=',' read -ra _items <<< "${csv}"
  for item in "${_items[@]}"; do [ "${item}" = "${needle}" ] && return 0; done
  return 1
}

for _sel in ${PREFLIGHT_ONLY} ${PREFLIGHT_SKIP}; do
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
  if [ -n "${PREFLIGHT_ONLY}" ]; then _in_csv "${slug}" "${PREFLIGHT_ONLY}" && return 0 || return 1; fi
  if [ -n "${PREFLIGHT_SKIP}" ]; then _in_csv "${slug}" "${PREFLIGHT_SKIP}" && return 1 || return 0; fi
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

# 0. Only git's w/ column counts: buildkit snapshots the worktree. See docs/code-quality-tooling.md#crlf-guard-the-worked-example
check_crlf_guard() {
  local offenders
  offenders="$(git ls-files -z 2>/dev/null \
    | xargs -0r bash linux/scripts/lint-shell.sh --list-files 2>/dev/null \
    | tr '\n' '\0' \
    | xargs -0r git ls-files --eol -- 2>/dev/null \
    | awk -F'\t' '{ split($1, c, /[ \t]+/)
        if (c[2] == "w/crlf" || c[2] == "w/mixed" || c[2] == "w/-text")
          printf "  %s  %s\n", c[2], $2 }' \
    || echo "__git-ls-files-FAILED__")"
  if [ -n "${offenders}" ]; then
    printf 'CRLF working-tree line endings detected in tracked shell script(s):\n'
    printf '%s\n' "${offenders}"
    printf 'Fix (re-materialize LF from the index): rm <file> && git checkout -- <file>\n'
    return 1
  fi
  printf 'no w/crlf, w/mixed or w/-text shell scripts in the working tree\n'
}
run_check crlf-guard "working-tree CRLF guard"    check_crlf_guard

# 1. Shell lint gate (shellcheck -S error across all scripts).
run_check shellcheck "shellcheck gate"            bash linux/scripts/lint-shell.sh

# 2. log() on fd 1 glues log lines onto a $(f) value; every /opt/scripts path is COPY'd into its image.
run_check stdout-returns "stdout-as-return-value" ${PREFLIGHT_PYTHON} linux/scripts/verify_stdout_returns.py
run_check copy-coverage "script COPY coverage"    ${PREFLIGHT_PYTHON} linux/scripts/verify_script_copy_coverage.py
# 2b. Every COPY/mount source still exists in its build context.
run_check context-paths "Dockerfile context paths" ${PREFLIGHT_PYTHON} linux/scripts/verify_dockerfile_context_paths.py

# 3. Critical-fix source integrity (incl. fix6: native-GCC system paths, bugs D/E).
run_check critical-fixes "critical fixes"         bash linux/scripts/verify-critical-fixes.sh

# 3b. Patch files are well-formed unified diffs AND still referenced (no orphans).
run_check patch-integrity "patch integrity"       bash linux/scripts/verify-patch-integrity.sh

# 3b2. Token-normalised, so a renamed clone still matches.
run_check code-dupes "code duplication"           ${PREFLIGHT_PYTHON} docs/scripts/verify_code_dupes.py

# 3c. Dockerfile.package artifact COPY paths stay canonical.
run_check artifact-parity "artifact copy parity"  bash linux/scripts/verify-artifact-copy-parity.sh

# 4. Dockerfile ARG names/values agree with versions.env + forwarding.
run_check arg-consistency "ARG consistency"       bash linux/scripts/01-core/verify-arg-consistency.sh

# 5. A missing script fails, never skips: absence means a broken tree or rename.
if [ -f docs/scripts/sync_versions.py ]; then
  run_check version-snapshot "version snapshot"   ${PREFLIGHT_PYTHON} docs/scripts/sync_versions.py --check
else
  run_check version-snapshot "version snapshot"   bash -c 'echo "docs/scripts/sync_versions.py MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# Docs cross-references + index coverage.
if [ -f docs/scripts/verify_doc_links.py ]; then
  run_check doc-links "docs cross-references"     ${PREFLIGHT_PYTHON} docs/scripts/verify_doc_links.py
else
  run_check doc-links "docs cross-references"     bash -c 'echo "docs/scripts/verify_doc_links.py MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# Docs duplication; a stale doc-dupes.allow entry fails too.
if [ -f docs/scripts/verify_doc_dupes.py ]; then
  run_check doc-dupes "docs duplication"          ${PREFLIGHT_PYTHON} docs/scripts/verify_doc_dupes.py
else
  run_check doc-dupes "docs duplication"          bash -c 'echo "docs/scripts/verify_doc_dupes.py MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# The curated SBOM covers the source-built (copyleft) components syft cannot read.
if [ -f docs/scripts/generate_sbom.py ]; then
  run_check sbom "curated SBOM"                   ${PREFLIGHT_PYTHON} docs/scripts/generate_sbom.py --check
else
  run_check sbom "curated SBOM"                   bash -c 'echo "docs/scripts/generate_sbom.py MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# KNOB_GATE=1 makes a ${VAR:-} knob without an owner a hard failure.
if [ -f linux/scripts/lint-env-knobs.sh ]; then
  run_check env-knobs "env-knob registry" env KNOB_GATE=1 bash linux/scripts/lint-env-knobs.sh
else
  run_check env-knobs "env-knob registry" bash -c 'echo "lint-env-knobs.sh MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# 6. Canonical Ubuntu mirror ARGs present across Dockerfiles.
if [ -f linux/scripts/01-core/verify-ubuntu-mirror-consistency.sh ]; then
  run_check mirror-consistency "ubuntu mirror consistency" bash linux/scripts/01-core/verify-ubuntu-mirror-consistency.sh
else
  run_check mirror-consistency "ubuntu mirror consistency" bash -c 'echo "verify-ubuntu-mirror-consistency.sh MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# 6b. A dead distro package name kills a stage hours in; offline degrades to a loud SKIP.
run_check pkg-names "distro package names" ${PREFLIGHT_PYTHON} linux/scripts/verify_package_names.py
run_check advert-keys "advertised version keys" ${PREFLIGHT_PYTHON} linux/scripts/verify_advertised_keys.py
run_check masked-decls "masked declarations" ${PREFLIGHT_PYTHON} linux/scripts/verify_masked_assignments.py
# A trailing bare test or `&&` list returns its status and kills set -e callers.
run_check trailing-conditional "trailing-conditional returns" ${PREFLIGHT_PYTHON} linux/scripts/verify_trailing_conditional.py
run_check comment-size "comment block size" ${PREFLIGHT_PYTHON} linux/scripts/verify_comment_size.py
run_check code-size "code size (functions + files)" ${PREFLIGHT_PYTHON} linux/scripts/verify_code_size.py
run_check code-complexity "cyclomatic complexity + nesting" ${PREFLIGHT_PYTHON} linux/scripts/verify_code_complexity.py
run_check dead-functions "dead shell functions" ${PREFLIGHT_PYTHON} linux/scripts/verify_dead_functions.py
run_check shellcheck-warnings "shellcheck warning ratchet" ${PREFLIGHT_PYTHON} linux/scripts/verify_shellcheck_warnings.py
# See docs/code-quality-tooling.md#the-mutation-gate-in-ci-sharded
: "${PREFLIGHT_MUTATION_SHARD:=}"
run_check mutations "mutation gate (can the tests fail?)" ${PREFLIGHT_PYTHON} docs/scripts/verify_mutations.py \
  ${PREFLIGHT_MUTATION_SHARD:+--shard "${PREFLIGHT_MUTATION_SHARD}"}
run_check gate-registry "gate proof registry" ${PREFLIGHT_PYTHON} linux/scripts/verify_gate_registry.py

# The bash twin: no hub Linux image ships pwsh. See shared/config/README.md
check_shared_config() {
  bash shared/config/sync-shared-config.sh --repo-root . --check
}
run_check shared-config "shared config owner-root sync" check_shared_config

# Subshell: the bootstrap's venv activate must not leak onto our PATH.
check_cmake_format() {
  (
    set -euo pipefail
    source linux/scripts/lib/code-quality.sh
    CODE_QUALITY_VENV_DIR="${PWD}/.venv-cmake-format"
    CODE_QUALITY_CMAKE_SEARCH_ROOT=.
    # The Windows patch shims' bytes are layer-cache keys; venvs can carry pip .cmake files.
    CODE_QUALITY_CMAKE_EXCLUDE_PATHS=(
      './.git/*' './third_party/*' './external/*'
      './windows/scripts/patches/*' './.venv*' './out/*'
    )
    code_quality_ensure_cmake_format
    local files=()
    mapfile -t files < <(code_quality_find_cmake_files)
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "cmake-format gate: the CMake file walk returned nothing - a broken scope/exclude list must not pass vacuously" >&2
      exit 1
    fi
    echo "checking ${#files[@]} CMake file(s) against .cmake-format.yaml"
    code_quality_run_cmake_format --check "${files[@]}"
  )
}
run_check cmake-format "cmake-format check" check_cmake_format

# 7. Runtime PATH/LD_LIBRARY_PATH/PKG_CONFIG_PATH match runtime-paths.env.
if [ -f linux/scripts/04-runtime/verify-runtime-paths.sh ]; then
  run_check runtime-paths "runtime path consistency" bash linux/scripts/04-runtime/verify-runtime-paths.sh
else
  run_check runtime-paths "runtime path consistency" bash -c 'echo "verify-runtime-paths.sh MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi

# 8. Dockerfile lint (hadolint, policy in .hadolint.yaml).
run_check dockerfile-lint "dockerfile lint (hadolint)" bash linux/scripts/lint-dockerfiles.sh

# 9. Arm a ramped workflow convention here once the repo is clean of it; until then workflow-conventions.allow holds it.
run_check workflow-lint "workflow lint (actionlint)" env WORKFLOW_CONVENTIONS_GATE=permissions bash linux/scripts/lint-workflows.sh

# Python gate: hard-fails only on real-error classes; full ruleset is advisory.
run_check python-lint "python lint (ruff)" bash linux/scripts/lint-python.sh

# Secret scan (enforcing); a false positive goes in .gitleaksignore with a justification.
run_check secret-scan "secret scan (gitleaks)" bash linux/scripts/lint-secrets.sh

# 10. The five parallel Android library stages stay identical modulo ANDROID_LIB.
run_check android-parity "android stage parity" bash linux/scripts/01-core/verify-android-stage-parity.sh

# 11. Unit tests for the tag/build-arg/disk-guard logic in linux/scripts.
run_check script-tests "linux script unit tests" bash linux/scripts/tests/run-tests.sh

# Stage-graph self-consistency (parent refs, dockerfiles, tags, cycles).
run_check stage-graph "cross stage graph validation" bash -c '
  source linux/scripts/01-core/modules.sh 2>/dev/null || true
  source linux/scripts/01-core/build-helpers.sh
  source linux/scripts/01-core/platform.sh
  source linux/scripts/01-core/tag-naming.sh
  source linux/scripts/01-core/stage-defs.sh
  IMAGE_REPO="${IMAGE_REPO:-preflight-check}" cross_stage_validate_graph'

# Warn-only: a submodule pin unreachable on its remote breaks every job that clones it.
_probe_submodule_pushed() {  # dir
  local dir="$1" recorded remote_tips tip
  [ -e "${dir}/.git" ] || return 0
  recorded="$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)"
  [ -n "${recorded}" ] || return 0
  # Offline, no remote or an auth failure all yield nothing: stay silent.
  remote_tips="$(timeout 10 git -C "${dir}" ls-remote --heads --tags origin 2>/dev/null | awk '{print $1}' || true)"
  [ -n "${remote_tips}" ] || return 0
  if printf '%s\n' "${remote_tips}" | grep -qxF "${recorded}"; then return 0; fi
  # Ancestry works only for remote tips whose objects are already local; a stale ref shows up as a false alarm.
  for tip in ${remote_tips}; do
    if git -C "${dir}" cat-file -e "${tip}^{commit}" 2>/dev/null \
       && git -C "${dir}" merge-base --is-ancestor "${recorded}" "${tip}" 2>/dev/null; then
      return 0
    fi
  done
  printf "${YELLOW}NOTE:${NC} submodule %s pin %.9s is not reachable on its remote (likeliest a STALE remote-tracking ref: run \`git -C %s fetch\` and re-run; otherwise an unpushed local commit or an upstream rewrite) — push it before a build/docs job that clones it.\n" \
    "${dir}" "${recorded}" "${dir}"
}
while IFS= read -r _sub_path; do
  [ -n "${_sub_path}" ] && _probe_submodule_pushed "${_sub_path}"
done < <(git config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
unset -f _probe_submodule_pushed 2>/dev/null || true

printf "\n${BOLD}=== preflight summary ===${NC}\n"
# A PREFLIGHT_ONLY/PREFLIGHT_SKIP that selects nothing must not report green.
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
