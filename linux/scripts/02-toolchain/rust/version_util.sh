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

if [[ "${1:-}" == "--normalize" ]]; then
    shift
    normalize_version "$1"
elif [[ "${1:-}" == "--sanitize" ]]; then
    shift
    sanitize_version "$1"
else
    info "Version utility - use --normalize or --sanitize"
    info "  --normalize <version>  - Normalize to Major.Minor.Build.Revision format"
    info "  --sanitize <version>   - Sanitize for use in filenames (replace slashes)"
fi