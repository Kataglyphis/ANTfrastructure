#!/bin/bash
# One release binary into a tar and, by --package-types, a deb, an AppImage and a flatpak; see docs/shared-script-libraries.md#06-packagingpackage_archivesh--one-binary-four-formats
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/logging.sh"

Workspace="${WORKSPACE:-$PWD}"
Binary="${BINARY:-}"
BinaryFile="${BINARY_FILE:-$Binary}"
BinaryPath="${BINARY_PATH:-}"
Version="${VERSION:-}"
ArchiveName="${ARCHIVE_NAME:-}"
ArchiveDir="${ARCHIVE_DIR:-dist}"
PackageTypes="${PACKAGE_TYPES:-tar}"
Platform="${PLATFORM:-}"
Arch="${ARCH:-}"

# Project files: the desktop entry and icon every format but the tar installs.
DesktopFile="${DESKTOP_FILE:-}"
IconFile="${ICON_FILE:-}"
AppID="${APP_ID:-}"

# Output behavior
WRITE_GITHUB_OUTPUT="${WRITE_GITHUB_OUTPUT:-true}"
ARCHIVE_OUT_FILE="${ARCHIVE_OUT_FILE:-}"
PRINT_ARCHIVE="${PRINT_ARCHIVE:-false}"

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) shift; Workspace="$1" ;;
        --binary) shift; Binary="$1" ;;
        --binary-file) shift; BinaryFile="$1" ;;
        --binary-path) shift; BinaryPath="$1" ;;
        --version) shift; Version="$1" ;;
        --archive-name) shift; ArchiveName="$1" ;;
        --archive-dir) shift; ArchiveDir="$1" ;;
        --platform) shift; Platform="$1" ;;
        --arch) shift; Arch="$1" ;;
        --package-types) shift; PackageTypes="$1" ;;
        --desktop-file) shift; DesktopFile="$1" ;;
        --icon-file) shift; IconFile="$1" ;;
        --app-id) shift; AppID="$1" ;;
        # Accepted and never read until 2026-10-06: the flatpak manifest is generated from the staged bundle now.
        --flatpak-manifest|--appdata-file)
            err "$1 was removed: the flatpak manifest is generated from the staged bundle (docs/shared-script-libraries.md)"
            exit 1 ;;
        --no-github-output) WRITE_GITHUB_OUTPUT=false ;;
        --appimage-extract-and-run) ;;
        --archive-out-file) shift; ARCHIVE_OUT_FILE="$1" ;;
        --print-archive) PRINT_ARCHIVE=true ;;
        *) warn "Unknown argument: $1" ;;
    esac
    shift
done

if [ -z "$DesktopFile" ]; then
    err "--desktop-file is required (no fallback allowed)"
    exit 1
fi

if [ -z "$IconFile" ]; then
    err "--icon-file is required (no fallback allowed)"
    exit 1
fi

if [ -z "$Binary" ]; then
    err "BINARY or --binary is required"
    exit 1
fi

# Checked before anything is built: an unknown format used to be skipped without a word.
read -r -a Formats <<< "$(printf '%s' "$PackageTypes" | tr '[:upper:],' '[:lower:] ')"
NeedsBundle=false
for format in "${Formats[@]}"; do
    case "$format" in
        tar) ;;
        deb|appimage|flatpak) NeedsBundle=true ;;
        *) err "unknown package type '$format' (tar, deb, appimage, flatpak)"; exit 1 ;;
    esac
done
if [ "$NeedsBundle" = true ] && [ -z "$Arch" ]; then
    err "--arch is required for deb, appimage and flatpak (x64 or arm64)"
    exit 1
fi

# Run packaging dependency preflight (best-effort)
bash "$SCRIPT_DIR/../02-toolchain/packaging-deps.sh" || true

cd "$Workspace"

for project_file in "$DesktopFile" "$IconFile"; do
    [ -f "$project_file" ] || { err "project file not found: $project_file"; exit 1; }
done
# Absolute, since the packagers run from their own staging dirs.
DesktopFile="$(cd "$(dirname "$DesktopFile")" && pwd)/$(basename "$DesktopFile")"
IconFile="$(cd "$(dirname "$IconFile")" && pwd)/$(basename "$IconFile")"

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

if [ -n "$BinaryPath" ]; then
    # Allow explicit binary path (useful for non-Rust projects)
    if [ ! -f "$BinaryPath" ]; then
        err "Release binary not found: $BinaryPath"
        exit 1
    fi
    SourceBinary="$BinaryPath"
elif [ -f "target/release/$BinaryFile" ]; then
    SourceBinary="target/release/$BinaryFile"
else
    err "Release binary not found: target/release/$BinaryFile (or provide --binary-path)"
    exit 1
fi
cp "$SourceBinary" "$ArchiveDir/$Binary"
tar -C "$ArchiveDir" -czvf "$ArchiveName" "$Binary"
rm "$ArchiveDir/$Binary"

info "Archive created successfully: $ArchiveName"

# Canonical archive path variable
ArchivePath="$ArchiveName"

if [ "$NeedsBundle" = true ]; then
    # The binary alone, under its package name, is the bundle app-packaging.sh packs for a Flutter app.
    Stage="${KATAGLYPHIS_PACKAGING_WORKDIR:-/tmp/packaging-work}/bundle"
    rm -rf "$Stage"
    mkdir -p "$Stage"
    install -m 0755 "$SourceBinary" "$Stage/$Binary"
    # deb wants a version that starts with a digit; a tag's leading v is not part of it.
    PackageVersion="${Version#v}"
    PackageVersion="${PackageVersion//\//-}"
    export APP_PACKAGING_BUNDLE_DIR="$Stage"
    export APP_PACKAGING_VERSION="${PackageVersion:-0.0.0}"
    export APP_PACKAGING_DESKTOP_FILE="$DesktopFile"
    export APP_PACKAGING_ICON_FILE="$IconFile"
    APP_PACKAGING_OUT_DIR="$(cd "$ArchiveDir" && pwd)"
    export APP_PACKAGING_OUT_DIR
    # A Rust binary links libc, libm and libgcc_s, not the GTK a Flutter bundle needs.
    export APP_PACKAGING_DEB_DEPENDS="${APP_PACKAGING_DEB_DEPENDS:-libc6, libgcc-s1}"
    if [ -n "$AppID" ]; then export APP_PACKAGING_APP_ID="$AppID"; fi
    # shellcheck source=../lib/app-packaging.sh
    source "$SCRIPT_DIR/../lib/app-packaging.sh"
    for format in "${Formats[@]}"; do
        case "$format" in
            deb) app_packaging_package_linux_bundle_deb "$Arch" "$Binary" ;;
            appimage) app_packaging_package_linux_bundle_appimage "$Arch" "$Binary" ;;
            flatpak) app_packaging_package_linux_bundle_flatpak "$Arch" "$Binary" ;;
        esac
    done
fi

export APPIMAGE_EXTRACT_AND_RUN=1

# Write archive path to optional file (workflow will pick this up)
if [ -n "$ARCHIVE_OUT_FILE" ]; then
    mkdir -p "$(dirname "$ARCHIVE_OUT_FILE")" || true
    echo "$ArchivePath" > "$ARCHIVE_OUT_FILE" || true
fi

# If running inside GH Actions and allowed, write to GITHUB_OUTPUT
if [ "$WRITE_GITHUB_OUTPUT" = "true" ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "ARCHIVE_PATH=$ArchivePath" >> "$GITHUB_OUTPUT" || true
fi

if [ "$PRINT_ARCHIVE" = "true" ]; then
    echo "$ArchivePath"
fi
