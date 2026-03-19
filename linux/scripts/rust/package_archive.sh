#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/logging.sh"

Workspace="${WORKSPACE:-$PWD}"
Binary="${BINARY:-}"
BinaryFile="${BINARY_FILE:-$Binary}"
Version="${VERSION:-}"
ArchiveName="${ARCHIVE_NAME:-}"
ArchiveDir="${ARCHIVE_DIR:-dist}"
Platform="${PLATFORM:-}"
Arch="${ARCH:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) shift; Workspace="$1" ;;
        --binary) shift; Binary="$1" ;;
        --binary-file) shift; BinaryFile="$1" ;;
        --version) shift; Version="$1" ;;
        --archive-name) shift; ArchiveName="$1" ;;
        --archive-dir) shift; ArchiveDir="$1" ;;
        --platform) shift; Platform="$1" ;;
        --arch) shift; Arch="$1" ;;
        *) warn "Unknown argument: $1" ;;
    esac
    shift
done

if [ -z "$Binary" ]; then
    err "BINARY or --binary is required"
    exit 1
fi

cd "$Workspace"

if [ -z "$ArchiveName" ]; then
    VersionSafe=$(echo "$Version" | tr '/' '-')
    if [ -n "$Platform" ] && [ -n "$Arch" ]; then
        ArchiveName="dist/${Binary}-${VersionSafe}-${Platform/\//_}-${Arch}.tar.gz"
    else
        ArchiveName="dist/${Binary}-${VersionSafe}.tar.gz"
    fi
fi

info "Creating archive: $ArchiveName"
info "Binary: $Binary"
info "Binary file: $BinaryFile"

mkdir -p "$(dirname "$ArchiveName")"
mkdir -p "$ArchiveDir"

if [ ! -f "target/release/$BinaryFile" ]; then
    err "Release binary not found: target/release/$BinaryFile"
    exit 1
fi

cp "target/release/$BinaryFile" "$ArchiveDir/$Binary"
tar -C "$ArchiveDir" -czvf "$ArchiveName" "$Binary"
rm "$ArchiveDir/$Binary"

info "Archive created successfully: $ArchiveName"

[ -n "${GITHUB_OUTPUT:-}" ] && echo "ARCHIVE_PATH=$ArchiveName" >> "$GITHUB_OUTPUT" || true