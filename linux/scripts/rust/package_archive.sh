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
PackageTypes="${PACKAGE_TYPES:-tar}"
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
        --package-types) shift; PackageTypes="$1" ;;
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

# Helper: create a simple .deb package using dpkg-deb if requested
create_deb() {
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        warn "dpkg-deb not found; skipping .deb creation"
        return
    fi

    DEB_DIR=$(mktemp -d)
    trap "rm -rf '$DEB_DIR'" EXIT

    pkgname="$Binary"
    vers_safe="$(echo "$Version" | tr '/' '-')"
    deb_maintainer="${DEB_MAINTAINER:-Unknown <noreply@example.com>}"
    deb_depends="${DEB_DEPENDS:-}" 

    case "$Arch" in
        x64|amd64) deb_arch="amd64" ;;
        arm64) deb_arch="arm64" ;;
        *) deb_arch="all" ;;
    esac

    mkdir -p "$DEB_DIR/usr/bin"
    cp "target/release/$BinaryFile" "$DEB_DIR/usr/bin/$Binary"
    chmod 0755 "$DEB_DIR/usr/bin/$Binary"

    # Include desktop file if provided in repository (packaging/flatpak/kataglyphis.desktop)
    if [ -f "packaging/flatpak/kataglyphis.desktop" ]; then
        mkdir -p "$DEB_DIR/usr/share/applications"
        cp "packaging/flatpak/kataglyphis.desktop" "$DEB_DIR/usr/share/applications/$pkgname.desktop"
        chmod 0644 "$DEB_DIR/usr/share/applications/$pkgname.desktop"
    fi

    # Include icon if provided at packaging/flatpak/icon.png (optional)
    if [ -f "packaging/flatpak/icon.png" ]; then
        mkdir -p "$DEB_DIR/usr/share/icons/hicolor/256x256/apps"
        cp "packaging/flatpak/icon.png" "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/$pkgname.png"
        chmod 0644 "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/$pkgname.png"
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

    if [ -n "$deb_depends" ]; then
        echo "Depends: $deb_depends" >> "$DEB_DIR/DEBIAN/control"
    fi

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

# Helper: best-effort AppImage creation if appimagetool is available
create_appimage() {
    if ! command -v appimagetool >/dev/null 2>&1; then
        warn "appimagetool not found; skipping AppImage creation"
        return
    fi

    APPDIR=$(mktemp -d)
    trap "rm -rf '$APPDIR'" EXIT

    mkdir -p "$APPDIR/usr/bin"
    cp "target/release/$BinaryFile" "$APPDIR/usr/bin/$Binary"
    chmod +x "$APPDIR/usr/bin/$Binary"

    # Minimal .desktop (placed where AppImage tooling expects it)
    mkdir -p "$APPDIR/usr/share/applications"
    cat > "$APPDIR/usr/share/applications/$Binary.desktop" <<EOF
[Desktop Entry]
Name=$Binary
Exec=$Binary
Icon=$Binary
Type=Application
Categories=Utility;
EOF

    # If a repo-provided icon exists, include it in common locations so
    # appimagetool can find it (it looks for IconName.{png,svg,xpm}).
    if [ -f "packaging/flatpak/icon.png" ]; then
        mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"
        cp "packaging/flatpak/icon.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$Binary.png"
        # also place a top-level copy which appimagetool will also detect
        cp "packaging/flatpak/icon.png" "$APPDIR/$Binary.png"
        chmod 0644 "$APPDIR/usr/share/icons/hicolor/256x256/apps/$Binary.png" || true
        chmod 0644 "$APPDIR/$Binary.png" || true
    fi

    out_appimage="$ArchiveDir/${Binary}-${Version//\//-}.AppImage"
    appimagetool "$APPDIR" "$out_appimage"
    info "AppImage created: $out_appimage"
}

# If PACKAGE_TYPES includes additional package types, create them.
IFS="," read -r -a types <<< "$PackageTypes"
for t in "${types[@]}"; do
    case "$t" in
        tar) ;;&
        gz) ;;&
        tgz) ;;&
        *)
            case "$t" in
                deb)
                    info "Requested .deb packaging"
                    create_deb
                    ;;
                appimage|AppImage)
                    info "Requested AppImage packaging"
                    create_appimage
                    ;;
                flatpak|Flatpak)
                    warn "Flatpak packaging requested but not automated by this script.\nTo create a Flatpak you should add a build manifest and use flatpak-builder in CI. See: https://docs.flatpak.org/en/latest/first-build.html"
                    ;;
                *)
                    warn "Unknown package type requested: $t"
                    ;;
            esac
            ;;
    esac
done
