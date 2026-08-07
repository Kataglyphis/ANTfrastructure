#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/logging.sh"

normalize_version() {
    local version="$1"
    version="${version#v}"
    if [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        version="$version.0"
    fi
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        version="0.1.0.0"
    fi
    echo "$version"
}

sanitize_version() {
    local version="$1"
    version="${version#v}"
    version="${version//\//-}"
    echo "$version"
}

# Resolve the version a CI run should stamp, from the sources every consumer
# has: a VERSION.txt at the repo root, else the ref name, else the run number.
#
# Lifted out of a consumer (Kataglyphis-RustProjectTemplate's
# Scripts/compute_version.sh) because every repo with a CI lane needs exactly
# this and had to reimplement it around the primitives above.
#
# The guards are load-bearing, in this order:
#   * only the FIRST NON-EMPTY line of VERSION.txt counts, CR-stripped and
#     trimmed - a file written on Windows otherwise yields "2.3.4\r", which is
#     not a valid version anywhere downstream;
#   * a leading "v" is dropped, so a v-prefixed tag works as a ref source;
#   * anything that still does not START WITH A DIGIT falls back to the run
#     number, which keeps a branch name like "feature/x" from becoming a
#     version. That guard is also why normalize_version's own "v" handling is
#     unreachable from here.
#
# One deliberate behaviour change from the consumer version this replaces:
# `read` returns non-zero on a final line with no trailing newline, so a plain
# `while IFS= read -r line` DROPS it. A VERSION.txt written without a trailing
# newline was therefore ignored outright and the run number stamped instead -
# silently, since the fallback looks like a normal result. The
# `|| [[ -n "$line" ]]` guard below reads that last line.
resolve_ci_version() {
    local version_file="${1:-VERSION.txt}"
    local ref_name="${2:-${REF_NAME:-}}"
    local run_number="${3:-${RUN_NUMBER:-}}"
    local file_ver="" line trimmed ver

    if [[ -f "$version_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            trimmed="${line//$'\r'/}"
            trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            if [[ -n "$trimmed" ]]; then
                file_ver="$trimmed"
                break
            fi
        done < "$version_file"
    fi

    if [[ -n "$file_ver" ]]; then
        ver="${file_ver#v}"
    else
        ver="${ref_name#v}"
        [[ -n "$ver" ]] || ver="$run_number"
    fi
    [[ "$ver" =~ ^[0-9] ]] || ver="$run_number"

    echo "$ver"
}

# Resolve, then publish as VERSION / MSIX_VERSION through BOTH channels a
# GitHub step can be consumed by: GITHUB_ENV for later steps in the same job,
# GITHUB_OUTPUT for `steps.<id>.outputs`. Safe to run outside Actions - both
# writes are skipped when the variables are unset.
emit_github_version() {
    local version_file="${1:-VERSION.txt}"
    local ver msix_ver

    ver="$(resolve_ci_version "$version_file")"
    msix_ver="$(normalize_version "$ver")"

    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf 'VERSION=%s\nMSIX_VERSION=%s\n' "$ver" "$msix_ver" >> "$GITHUB_ENV"
    fi
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'VERSION=%s\nMSIX_VERSION=%s\n' "$ver" "$msix_ver" >> "$GITHUB_OUTPUT"
    fi

    info "Computed VERSION=${ver}"
    info "Computed MSIX_VERSION=${msix_ver}"
}

if [[ "${1:-}" == "--normalize" ]]; then
    shift
    normalize_version "$1"
elif [[ "${1:-}" == "--sanitize" ]]; then
    shift
    sanitize_version "$1"
elif [[ "${1:-}" == "--resolve-ci" ]]; then
    shift
    resolve_ci_version "${1:-VERSION.txt}"
elif [[ "${1:-}" == "--github-env" ]]; then
    shift
    emit_github_version "${1:-VERSION.txt}"
else
    info "Version utility"
    info "  --normalize <version>   - Normalize to Major.Minor.Build.Revision"
    info "  --sanitize  <version>   - Sanitize for filenames (replace slashes)"
    info "  --resolve-ci [file]     - Resolve the CI version (VERSION.txt / REF_NAME / RUN_NUMBER)"
    info "  --github-env [file]     - Resolve and write VERSION + MSIX_VERSION to GITHUB_ENV/OUTPUT"
fi