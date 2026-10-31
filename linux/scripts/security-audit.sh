#!/usr/bin/env bash
# Lockfile vulnerability audit; not covered: reachability, vendored or third_party code, container images. See docs/vulnerability-scanning.md#lockfile-audit-security-auditsh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${SCRIPTS}/01-core"
LOCKFILE_NAMES=(uv.lock Cargo.lock pubspec.lock package-lock.json)

usage() {
  cat <<'EOF'
Usage: security-audit.sh [--root DIR] [--mode gate|report] [--base REV] [--output FILE]

  --mode report  list every finding and succeed (schedule, workflow_dispatch; default)
  --mode gate    fail when a HIGH or CRITICAL finding's package@version is absent from
                 the --base commit's copy of its lockfile (push, pull_request)
EOF
}

# shellcheck source=lib/cli-value-options.sh
source "${SCRIPTS}/lib/cli-value-options.sh"
err() { printf 'security-audit: ERROR: %s\n' "$*" >&2; exit 2; }

_audit_flag() {
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; err "unknown argument: $1" ;;
  esac
}

security_audit_parse_args() {
  local -A _value_options=([--root]=ROOT [--mode]=MODE [--base]=BASE [--output]=OUTPUT)
  parse_cli_value_options _value_options REST _audit_flag "$@"
}

ROOT="${PWD}" MODE=report BASE="" OUTPUT=security-audit.json REST=()
security_audit_parse_args "$@"
[ "${#REST[@]}" -eq 0 ] || err "unexpected arguments: ${REST[*]}"
case "${MODE}" in gate|report) ;; *) err "--mode must be gate or report, not ${MODE}" ;; esac
ROOT="$(cd "${ROOT}" && pwd)" || err "--root ${ROOT} is not a directory"
[ "${MODE}" = report ] || [ -n "${BASE}" ] || err "--mode gate needs --base"

_git() { git -c safe.directory='*' -C "${ROOT}" "$@"; }

osv_release_asset() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64) printf 'osv-scanner_linux_amd64 %s\n' "${OSV_SCANNER_LINUX_AMD64_SHA256:-}" ;;
    Linux/aarch64|Linux/arm64) printf 'osv-scanner_linux_arm64 %s\n' "${OSV_SCANNER_LINUX_ARM64_SHA256:-}" ;;
    *) return 1 ;;
  esac
}

# Sets OSV_SCANNER and OSV_SCANNER_REPORTED; a scanner that cannot run fails, never reads as zero findings.
osv_scanner_resolve() {
  local asset sha cache
  # shellcheck source=01-core/load-versions-env.sh
  source "${CORE_DIR}/load-versions-env.sh"
  load_versions_env "${CORE_DIR}/tool-pins.env"
  [ -n "${OSV_SCANNER_VERSION:-}" ] || err "OSV_SCANNER_VERSION is not set (tool-pins.env not found?)"
  OSV_SCANNER="${SECURITY_AUDIT_OSV_SCANNER:-}"
  if [ -z "${OSV_SCANNER}" ]; then
    read -r asset sha < <(osv_release_asset) || err "no osv-scanner release for $(uname -s)/$(uname -m)"
    [ -n "${sha}" ] || err "no pinned osv-scanner SHA256 for ${asset}; add one to tool-pins.env"
    cache="${XDG_CACHE_HOME:-${HOME}/.cache}/kataglyphis-lint/osv-scanner-${OSV_SCANNER_VERSION}"
    OSV_SCANNER="${cache}/osv-scanner"
    if [ ! -x "${OSV_SCANNER}" ]; then
      # shellcheck source=01-core/downloads.sh
      source "${CORE_DIR}/downloads.sh"
      download_verified_install \
        "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/${asset}" \
        "${sha}" "${OSV_SCANNER}" || err "verified install of ${asset} failed"
    fi
  fi
  [ -x "${OSV_SCANNER}" ] || err "osv-scanner ${OSV_SCANNER} is not an executable file"
  OSV_SCANNER_REPORTED="$("${OSV_SCANNER}" --version 2>/dev/null | sed -n 's/^osv-scanner version: //p')" \
    || err "osv-scanner ${OSV_SCANNER} does not run"
  [ -n "${OSV_SCANNER_REPORTED}" ] || err "osv-scanner ${OSV_SCANNER} reports no version"
  [ -n "${SECURITY_AUDIT_OSV_SCANNER:-}" ] || [ "${OSV_SCANNER_REPORTED}" = "${OSV_SCANNER_VERSION}" ] \
    || err "osv-scanner reports ${OSV_SCANNER_REPORTED}, not the pinned ${OSV_SCANNER_VERSION}"
}

tracked_lockfiles() {
  local name specs=()
  for name in "${LOCKFILE_NAMES[@]}"; do specs+=(":(glob)**/${name}"); done
  _git ls-files -- "${specs[@]}" ':(exclude)third_party/**'
}

# A base commit without the lockfile leaves no copy, so every finding in it counts as new.
export_base_lockfiles() {
  local dest="$1" sha lock
  sha="$(_git rev-parse --verify --quiet "${BASE}^{commit}")" || err "base ${BASE} is not a commit in ${ROOT}"
  BASE="${sha}"
  for lock in "${LOCKFILES[@]}"; do
    if _git cat-file -e "${sha}:${lock}" 2>/dev/null; then
      mkdir -p "${dest}/$(dirname "${lock}")"
      _git show "${sha}:${lock}" > "${dest}/${lock}"
    fi
  done
}

# cargo_security_checks.sh gates in each Rust repo's own lane; here its verdict is recorded.
run_cargo_checks() {
  local out="$1" lock rc
  for lock in "${LOCKFILES[@]}"; do
    [ "$(basename "${lock}")" = Cargo.lock ] || continue
    command -v cargo >/dev/null 2>&1 || err "cargo is not on PATH, so ${lock} cannot be graded by cargo_security_checks.sh"
    rc=0
    ( cd "${ROOT}/$(dirname "${lock}")" && bash "${SCRIPTS}/02-toolchain/rust/cargo_security_checks.sh" ) || rc=$?
    printf '%s\t%s\n' "${lock}" "${rc}" >> "${out}"
  done
}

osv_scanner_resolve
mapfile -t LOCKFILES < <(tracked_lockfiles)
echo "== security audit under ${ROOT}: osv-scanner ${OSV_SCANNER_REPORTED}, mode ${MODE}, ${#LOCKFILES[@]} lockfile(s) =="
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
printf '%s\n' "${LOCKFILES[@]}" > "${WORK}/lockfiles"
: > "${WORK}/cargo.tsv"
if [ "${#LOCKFILES[@]}" -eq 0 ]; then
  printf '{"results": []}\n' > "${WORK}/osv.json"
else
  scan=(scan source --all-packages --no-call-analysis=all --format json --output-file "${WORK}/osv.json")
  for lock in "${LOCKFILES[@]}"; do scan+=(--lockfile "${ROOT}/${lock}"); done
  rc=0
  "${OSV_SCANNER}" "${scan[@]}" > "${WORK}/osv.log" 2>&1 || rc=$?
  # osv-scanner exits 1 when it found vulnerabilities; every other nonzero status is a failed scan.
  if [ "${rc}" -gt 1 ]; then cat "${WORK}/osv.log" >&2; err "osv-scanner exited ${rc}"; fi
  [ -s "${WORK}/osv.json" ] || { cat "${WORK}/osv.log" >&2; err "osv-scanner wrote no JSON"; }
  run_cargo_checks "${WORK}/cargo.tsv"
fi
grade=(--osv "${WORK}/osv.json" --root "${ROOT}" --lockfiles "${WORK}/lockfiles" --mode "${MODE}"
  --cargo "${WORK}/cargo.tsv" --scanner-version "${OSV_SCANNER_REPORTED}" --output "${OUTPUT}")
if [ "${MODE}" = gate ]; then
  mkdir -p "${WORK}/base"
  export_base_lockfiles "${WORK}/base"
  grade+=(--base "${BASE}" --base-dir "${WORK}/base")
fi
python3 -I "${SCRIPTS}/security_audit.py" "${grade[@]}"
