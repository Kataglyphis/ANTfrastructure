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

# A Cargo.toml's version: [workspace.package] first, else [package]; "version.workspace = true" is no version.
cargo_toml_version() {
    awk '
      /^[[:space:]]*\[/ { section = $0; gsub(/[[:space:]]/, "", section); next }
      /^[[:space:]]*version[[:space:]]*=[[:space:]]*"/ {
        v = $0; sub(/^[^"]*"/, "", v); sub(/".*/, "", v)
        if (section == "[workspace.package]") { ws = v }
        else if (section == "[package]" && pkg == "") { pkg = v }
      }
      END { if (ws != "") print ws; else if (pkg != "") print pkg }
    ' "$1"
}

# A CMakeLists.txt's version: the first project() call's literal VERSION; a ${VAR} there is no version.
cmake_project_version() {
    awk '
      { sub(/#.*/, ""); text = text " " $0 }
      END {
        if (!match(tolower(text), /(^|[^a-z0-9_])project[ \t]*\(/)) exit
        rest = substr(text, RSTART + RLENGTH); j = index(rest, ")")
        if (j == 0) exit
        n = split(substr(rest, 1, j - 1), tok, /[ \t]+/)
        for (k = 1; k < n; k++) if (tok[k] == "VERSION" && tok[k + 1] ~ /^[0-9]+(\.[0-9]+)*$/) { print tok[k + 1]; exit }
      }
    ' "$1"
}

# The version a file states, empty when none: a Cargo.toml's, a CMakeLists.txt's project(), a pubspec.yaml's without its +build, else a plain file's first line.
file_version() {
    local version_file="$1" line trimmed
    [[ -f "$version_file" ]] || return 0
    case "$(basename "$version_file")" in
        Cargo.toml) cargo_toml_version "$version_file"; return 0 ;;
        CMakeLists.txt) cmake_project_version "$version_file"; return 0 ;;
        pubspec.yaml) sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$version_file" | head -n 1; return 0 ;;
    esac
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="${line//$'\r'/}"
        trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        if [[ -n "$trimmed" ]]; then
            printf '%s\n' "$trimmed"
            return 0
        fi
    done < "$version_file"
}

# docs/cross-build-verification.md#resolve_ci_version-the-version-a-ci-run-stamps
resolve_ci_version() {
    local version_file="${1:-VERSION.txt}"
    local ref_name="${2:-${REF_NAME:-}}"
    local run_number="${3:-${RUN_NUMBER:-}}"
    local file_ver ver

    file_ver="$(file_version "$version_file")"

    if [[ -n "$file_ver" ]]; then
        ver="${file_ver#v}"
    else
        ver="${ref_name#v}"
        [[ -n "$ver" ]] || ver="$run_number"
    fi
    [[ "$ver" =~ ^[0-9] ]] || ver="$run_number"

    echo "$ver"
}

# Publishes to GITHUB_ENV and GITHUB_OUTPUT alike, so later steps and step outputs both see it; no-op outside Actions.
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
elif [[ "${1:-}" == "--file-version" ]]; then
    shift
    ver="$(file_version "${1:?--file-version needs a file}")"
    [[ "$ver" =~ ^v?[0-9] ]] || err "no version in ${1}"
    printf '%s\n' "${ver#v}"
elif [[ "${1:-}" == "--github-env" ]]; then
    shift
    emit_github_version "${1:-VERSION.txt}"
else
    info "Version utility"
    info "  --normalize <version>   - Normalize to Major.Minor.Build.Revision"
    info "  --sanitize  <version>   - Sanitize for filenames (replace slashes)"
    info "  --resolve-ci [file]     - Resolve the CI version (VERSION.txt or a Cargo.toml / REF_NAME / RUN_NUMBER)"
    info "  --file-version <file>   - The version a VERSION.txt, Cargo.toml or pubspec.yaml states; fails without one"
    info "  --github-env [file]     - Resolve and write VERSION + MSIX_VERSION to GITHUB_ENV/OUTPUT"
fi