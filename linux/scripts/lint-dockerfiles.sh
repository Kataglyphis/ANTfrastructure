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
# Usage: linux/scripts/lint-dockerfiles.sh [Dockerfile ...]
#   With no arguments, lints the full known set (Linux chain + services +
#   Windows). LINT_DOCKERFILES_BUILD_CHECK=0 skips the advisory pass entirely.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Target set
# ---------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  DOCKERFILES=("$@")
else
  DOCKERFILES=()
  for df in linux/Dockerfile.* linux/webserver/Dockerfile linux/llm-stack/Dockerfile \
            windows/Dockerfile windows/Dockerfile.*; do
    [ -f "${df}" ] && DOCKERFILES+=("${df}")
  done
fi
[ "${#DOCKERFILES[@]}" -gt 0 ] || err "No Dockerfiles found to lint."

# ---------------------------------------------------------------------------
# hadolint bootstrap (PATH copy preferred; else pinned, SHA-verified download)
# ---------------------------------------------------------------------------
hadolint_load_pin() {
  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh"
  load_versions_env "${CORE_DIR}/versions.env"
}

hadolint_asset_and_sha() {
  local os arch
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

FAILED=0
for df in "${DOCKERFILES[@]}"; do
  hl_args=(--config "${REPO_ROOT}/.hadolint.yaml")
  case "${df}" in
    windows/*)
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
if [ "${LINT_DOCKERFILES_BUILD_CHECK:-1}" = "1" ] \
   && command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1 \
   && docker version --format '{{.Server.Os}}' >/dev/null 2>&1; then
  printf '\n== docker buildx build --check (advisory) ==\n'
  for df in "${DOCKERFILES[@]}"; do
    # Windows Dockerfiles use `# escape=`` + servercore bases; the Linux
    # BuildKit frontend still parses them, but skip them to avoid noise on
    # hosts without a Windows daemon.
    case "${df}" in windows/*) continue ;; esac
    if docker buildx build --check -f "${df}" . >/dev/null 2>&1; then
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
