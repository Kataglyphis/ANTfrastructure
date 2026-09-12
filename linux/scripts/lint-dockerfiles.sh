#!/usr/bin/env bash
# lint-dockerfiles.sh — static Dockerfile gate: hadolint (+ optional BuildKit
# frontend lint). No image is ever built here; this is safe for CI and hooks.
#
# hadolint is bootstrapped on demand: PATH copy is used when present, otherwise
# the pinned release (HADOLINT_VERSION / HADOLINT_*_SHA256 in versions.env) is
# downloaded once into a version-keyed cache dir and SHA256-verified — the same
# pattern as linux/scripts/lib/wasm-opt.sh for binaryen.
#
# Rule policy lives in .hadolint.yaml at the repo root. Deliberately permissive
# at adoption: do NOT edit Dockerfile lines just to satisfy a rule — every byte
# change invalidates multi-hour build layers. Tighten the config instead.
#
# The optional second pass runs `docker buildx build --check` per Dockerfile
# (BuildKit frontend lint: parses + runs frontend checks, executes no RUN and
# pulls no base images — only the dockerfile frontend image). It is advisory
# and auto-skipped when docker/buildx is unavailable (e.g. nerdctl-only hosts).
#
# Usage: linux/scripts/lint-dockerfiles.sh [--root <dir>] [Dockerfile ...]
#   With no file arguments, lints the full known set (Linux chain + services +
#   Windows). LINT_DOCKERFILES_BUILD_CHECK=0 skips the advisory pass entirely.
#
# --root is the same contract lint-workflows.sh, lint-shell.sh and lint-python.sh
# document, for the same reason: a submodule checkout puts this script INSIDE
# the consumer, where the default root resolves to ANTfrastructure and the gate
# grades the wrong tree while reporting green over one nobody looked at. The
# hadolint bootstrap, its cache and versions.env always come from THIS repo.
#
# Under a root the file set is `git ls-files`, not the hub's fixed glob list: a
# vendored submodule (this very repo, at third_party/ANTfrastructure) is a GITLINK
# there, so the consumer's scope cannot quietly swallow the hub's own 20-odd
# Dockerfiles and report their verdict as the consumer's. The root must be a git
# checkout, which is checked rather than assumed.
#
# The rule config follows the tree too, on the lint-secrets.sh precedent: a
# consumer shipping its own .hadolint.yaml is graded by ITS waivers, since the
# hub's say nothing about a Dockerfile the hub never wrote.
#
# An empty file list is already fatal below and stays fatal under a root — a
# consumer with no Dockerfile gets an error, never a green verdict about
# nothing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

: "${LINT_DOCKERFILES_BUILD_CHECK:=1}"

# --root is parsed and resolved by the contract's one owner; what comes back is
# the tree to grade. The remaining arguments go back into "$@", so the explicit
# file-list call shape below is untouched.
# shellcheck source=01-core/lint-root.sh
. "${CORE_DIR}/lint-root.sh"
lint_root_begin "${REPO_ROOT}" "$@" || exit 1
SCAN_ROOT="${LINT_ROOT_PATH}"
set -- ${LINT_ROOT_REST[@]+"${LINT_ROOT_REST[@]}"}

# The hub's .hadolint.yaml unless the consumer ships one of its own.
HADOLINT_CONFIG="${REPO_ROOT}/.hadolint.yaml"
[ -f "${SCAN_ROOT}/.hadolint.yaml" ] && HADOLINT_CONFIG="${SCAN_ROOT}/.hadolint.yaml"

# ---------------------------------------------------------------------------
# Target set
# ---------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  DOCKERFILES=("$@")
elif [ "${LINT_ROOT_GIVEN}" -eq 1 ]; then
  DOCKERFILES=()
  while IFS= read -r -d '' df; do
    DOCKERFILES+=("${SCAN_ROOT}/${df}")
  done < <(lint_root_tracked "${SCAN_ROOT}" 'Dockerfile' 'Dockerfile.*' \
             '*/Dockerfile' '*/Dockerfile.*')
else
  DOCKERFILES=()
  for df in linux/Dockerfile.* linux/webserver/Dockerfile linux/llm-stack/Dockerfile \
            windows/Dockerfile windows/Dockerfile.*; do
    [ -f "${df}" ] && DOCKERFILES+=("${df}")
  done
fi
[ "${#DOCKERFILES[@]}" -gt 0 ] || err "No Dockerfiles found to lint under ${SCAN_ROOT}."
printf '== dockerfile lint under %s ==\n' "${SCAN_ROOT}"

FAILED=0

# ---------------------------------------------------------------------------
# Pass 0: ENV instruction ordering (enforced, no download)
# hadolint has no rule for it and BuildKit's UndefinedVar check only runs in the
# advisory pass, which is skipped on every nerdctl-only host.
# docs/code-quality-tooling.md#env-instruction-ordering-dockerfile-lint
# ---------------------------------------------------------------------------
printf '== ENV instruction ordering on %d Dockerfile(s) ==\n' "${#DOCKERFILES[@]}"
python3 linux/scripts/verify_dockerfile_env_order.py "${DOCKERFILES[@]}" || FAILED=1

# ---------------------------------------------------------------------------
# hadolint bootstrap (PATH copy preferred; else pinned, SHA-verified download)
# ---------------------------------------------------------------------------
hadolint_load_pin() {
  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh"
  load_versions_env "${CORE_DIR}/versions.env"
}

hadolint_asset_and_sha() {
  local os
  case "$(uname -s)" in
    Linux) os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)
      if [ "${os}" = windows ]; then
        printf 'hadolint-windows-x86_64.exe %s\n' "${HADOLINT_WINDOWS_X86_64_SHA256:-}"
      else
        printf 'hadolint-linux-x86_64 %s\n' "${HADOLINT_LINUX_X86_64_SHA256:-}"
      fi ;;
    aarch64|arm64) printf 'hadolint-linux-arm64 %s\n' "${HADOLINT_LINUX_ARM64_SHA256:-}" ;;
    *) return 1 ;;
  esac
}

hadolint_ensure() {
  if command -v hadolint >/dev/null 2>&1; then
    HADOLINT_BIN="$(command -v hadolint)"
    return 0
  fi

  hadolint_load_pin
  [ -n "${HADOLINT_VERSION:-}" ] || err "HADOLINT_VERSION is not set (versions.env not found?)."

  local asset expected_sha cache_root bin_name
  read -r asset expected_sha < <(hadolint_asset_and_sha) \
    || err "Unsupported platform for hadolint bootstrap ($(uname -s)/$(uname -m)); install hadolint on PATH instead."
  [ -n "${expected_sha}" ] || err "No pinned hadolint SHA256 for ${asset}; add one to versions.env."

  cache_root="${HADOLINT_CACHE_DIR:-${TMPDIR:-/tmp}}/hadolint-${HADOLINT_VERSION}"
  bin_name="hadolint"; case "${asset}" in *.exe) bin_name="hadolint.exe" ;; esac
  HADOLINT_BIN="${cache_root}/${bin_name}"

  if [ ! -x "${HADOLINT_BIN}" ]; then
    # shellcheck source=01-core/downloads.sh
    source "${CORE_DIR}/downloads.sh" || err "downloads.sh not available for verified hadolint fetch"
    mkdir -p "${cache_root}" || err "Cannot create hadolint cache directory ${cache_root}"
    download_verified_file \
      "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${asset}" \
      "${expected_sha}" \
      "${HADOLINT_BIN}" \
      || err "Verified download of ${asset} failed (checksum mismatch or network error)."
    chmod +x "${HADOLINT_BIN}"
  fi
}

# ---------------------------------------------------------------------------
# Pass 1: hadolint (enforced)
# ---------------------------------------------------------------------------
hadolint_ensure
printf '== hadolint (%s) on %d Dockerfile(s) ==\n' "$("${HADOLINT_BIN}" --version)" "${#DOCKERFILES[@]}"

# Which hadolint rules are waived and why:
# docs/code-quality-tooling.md
HADOLINT_WINDOWS_IGNORES=(
  SC1009 SC1035 SC1046 SC1047 SC1056 SC1064 SC1066
  SC1070 SC1071 SC1072 SC1073 SC1078 SC1079 SC1083
  SC1088 SC1089 SC1099
)

for df in "${DOCKERFILES[@]}"; do
  hl_args=(--config "${HADOLINT_CONFIG}")
  # Under a root the paths are absolute, so the prefix arm alone would stop
  # matching and every Windows Dockerfile would be graded by Linux SC rules.
  case "${df}" in
    windows/*|*/windows/*)
      for rule in "${HADOLINT_WINDOWS_IGNORES[@]}"; do hl_args+=(--ignore "${rule}"); done ;;
  esac
  if "${HADOLINT_BIN}" "${hl_args[@]}" "${df}"; then
    printf '  ok: %s\n' "${df}"
  else
    printf '  FAIL: %s\n' "${df}" >&2
    FAILED=1
  fi
done

# ---------------------------------------------------------------------------
# Pass 2: BuildKit frontend lint (advisory; auto-skipped without docker buildx)
# ---------------------------------------------------------------------------
if [ "${LINT_DOCKERFILES_BUILD_CHECK}" = "1" ] \
   && command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1 \
   && docker version --format '{{.Server.Os}}' >/dev/null 2>&1; then
  printf '\n== docker buildx build --check (advisory) ==\n'
  for df in "${DOCKERFILES[@]}"; do
    # Windows Dockerfiles use `# escape=`` + servercore bases; the Linux
    # BuildKit frontend still parses them, but skip them to avoid noise on
    # hosts without a Windows daemon.
    case "${df}" in windows/*|*/windows/*) continue ;; esac
    if docker buildx build --check -f "${df}" "${SCAN_ROOT}" >/dev/null 2>&1; then
      printf '  ok: %s\n' "${df}"
    else
      printf '  note: --check reported issues in %s (advisory, not failing the gate)\n' "${df}"
    fi
  done
else
  printf '\n(docker buildx unavailable or disabled — skipping advisory --check pass)\n'
fi

if [ "${FAILED}" -ne 0 ]; then
  printf '\nDOCKERFILE LINT FAILED\n' >&2
  exit 1
fi
printf '\nDOCKERFILE LINT OK\n'
