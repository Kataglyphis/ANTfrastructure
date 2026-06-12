#!/usr/bin/env bash
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

# Optional overrides for project-specific files (defaults are empty -> auto-detect)
FlatpakManifest="${FLATPAK_MANIFEST:-}"
DesktopFile="${DESKTOP_FILE:-}"
IconFile="${ICON_FILE:-}"
AppDataFile="${APPDATA_FILE:-}"
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
        --flatpak-manifest) shift; FlatpakManifest="$1" ;;
        --desktop-file) shift; DesktopFile="$1" ;;
        --icon-file) shift; IconFile="$1" ;;
        --appdata-file) shift; AppDataFile="$1" ;;
        --app-id) shift; AppID="$1" ;;
        --no-github-output) WRITE_GITHUB_OUTPUT=false ;;
        --archive-out-file) shift; ARCHIVE_OUT_FILE="$1" ;;
        --print-archive) PRINT_ARCHIVE=true ;;
        *) warn "Unknown argument: $1" ;;
    esac
    shift
done

# Require explicit project files — remove legacy fallbacks
if [ -z "$DesktopFile" ]; then
    err "--desktop-file is required (no fallback allowed)"
    exit 1
fi

if [ -z "$IconFile" ]; then
    err "--icon-file is required (no fallback allowed)"
    exit 1
fi

# If Flatpak packaging is requested, require an explicit manifest
if echo "$PackageTypes" | tr '[:upper:]' '[:lower:]' | grep -q "flatpak"; then
    if [ -z "$FlatpakManifest" ]; then
        err "--flatpak-manifest is required when PackageTypes includes Flatpak"
        exit 1
    fi
fi

# Run packaging dependency preflight (best-effort, including Flatpak runtimes)
PACKAGING_DEPS_MODE=best-effort INSTALL_FLATPAK_RUNTIMES=true \
    bash "$SCRIPT_DIR/../02-toolchain/packaging-deps.sh" || true

if [ -z "$Binary" ]; then
    err "BINARY or --binary is required"
    exit 1
fi

cd "$Workspace"

if [ -z "$ArchiveName" ]; then
    VersionSafe="${Version//\//-}"
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

# Packaging dependency installation was moved to
# ../02-toolchain/packaging-deps.sh. That script is invoked earlier and
# is responsible for installing prerequisites (appimagetool, flatpak, etc.).
if [ -n "$BinaryPath" ]; then
    # Allow explicit binary path (useful for non-Rust projects)
    if [ ! -f "$BinaryPath" ]; then
        err "Release binary not found: $BinaryPath"
        exit 1
    fi
    cp "$BinaryPath" "$ArchiveDir/$Binary"
elif [ -f "target/release/$BinaryFile" ]; then
    cp "target/release/$BinaryFile" "$ArchiveDir/$Binary"
else
    err "Release binary not found: target/release/$BinaryFile (or provide --binary-path)"
    exit 1
fi
# ResolvedBinary points to the actual binary used for packaging (in $ArchiveDir)
ResolvedBinary="$ArchiveDir/$Binary"
tar -C "$ArchiveDir" -czvf "$ArchiveName" "$Binary"
rm "$ArchiveDir/$Binary"

info "Archive created successfully: $ArchiveName"

# Canonical archive path variable
ArchivePath="$ArchiveName"

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

# Helper: create a simple .deb package using dpkg-deb if requested
create_deb() {
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        warn "dpkg-deb not found; skipping .deb creation"
        return
    fi

    DEB_DIR=$(mktemp -d)
    trap "rm -rf '${DEB_DIR}'" EXIT

    pkgname="$Binary"
    vers_safe="${Version//\//-}"
    deb_maintainer="${DEB_MAINTAINER:-Unknown <noreply@example.com>}"
    deb_depends="${DEB_DEPENDS:-}" 

    case "$Arch" in
        x64|amd64) deb_arch="amd64" ;;
        arm64) deb_arch="arm64" ;;
        *) deb_arch="all" ;;
    esac

    mkdir -p "$DEB_DIR/usr/bin"
    # Use the resolved binary (copied earlier into $ArchiveDir) when available
    if [ -n "${ResolvedBinary:-}" ] && [ -f "${ResolvedBinary}" ]; then
        cp "${ResolvedBinary}" "$DEB_DIR/usr/bin/$Binary"
    elif [ -f "target/release/$BinaryFile" ]; then
        cp "target/release/$BinaryFile" "$DEB_DIR/usr/bin/$Binary"
    else
        err "Cannot locate binary for .deb: tried ResolvedBinary and target/release/$BinaryFile"
        return
    fi
    chmod 0755 "$DEB_DIR/usr/bin/$Binary"

    # Include desktop file: must be provided (no fallback)
    if [ -n "$DesktopFile" ] && [ -f "$DesktopFile" ]; then
        mkdir -p "$DEB_DIR/usr/share/applications"
        cp "$DesktopFile" "$DEB_DIR/usr/share/applications/$pkgname.desktop"
        chmod 0644 "$DEB_DIR/usr/share/applications/$pkgname.desktop"
    else
        err "Desktop file for .deb not found: $DesktopFile"
        return
    fi

    # Include icon file: must be provided (no fallback)
    if [ -n "$IconFile" ] && [ -f "$IconFile" ]; then
        mkdir -p "$DEB_DIR/usr/share/icons/hicolor/256x256/apps"
        cp "$IconFile" "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/$pkgname.png"
        chmod 0644 "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/$pkgname.png"
    else
        err "Icon file for .deb not found: $IconFile"
        return
    fi

    mkdir -p "$DEB_DIR/DEBIAN"
    # Write the control file in parts to avoid inserting an empty blank line
    # when there are no Depends. A blank line would terminate the control
    # paragraph and cause dpkg-deb to parse multiple package stanzas.
    cat > "$DEB_DIR/DEBIAN/control" <<EOF
Package: $pkgname
Version: $vers_safe
Section: utils
Priority: optional
Architecture: $deb_arch
Maintainer: $deb_maintainer
EOF

    cat >> "$DEB_DIR/DEBIAN/control" <<EOF
Description: $pkgname (packaged from CI)
EOF

    # Optionally include maintainer scripts if provided via environment variables
    if [ -n "${DEB_PREINST:-}" ]; then
        echo "$DEB_PREINST" > "$DEB_DIR/DEBIAN/preinst"
        chmod 0755 "$DEB_DIR/DEBIAN/preinst"
    fi
    if [ -n "${DEB_POSTINST:-}" ]; then
        echo "$DEB_POSTINST" > "$DEB_DIR/DEBIAN/postinst"
        chmod 0755 "$DEB_DIR/DEBIAN/postinst"
    fi

    # If we packaged a desktop entry or icon, add a small postinst to refresh caches if possible
    if [ -f "$DEB_DIR/usr/share/applications/$pkgname.desktop" ] || [ -f "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/$pkgname.png" ]; then
        cat > "$DEB_DIR/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
POSTINST
        chmod 0755 "$DEB_DIR/DEBIAN/postinst"
    fi

    out_deb="$ArchiveDir/${pkgname}_${vers_safe}_${deb_arch}.deb"
    dpkg-deb --build "$DEB_DIR" "$out_deb"
    info ".deb created: $out_deb"
}
