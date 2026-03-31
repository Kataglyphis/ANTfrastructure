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

# Ensure appimagetool is available; try to download a matching AppImage if missing
ensure_appimagetool() {
    if command -v appimagetool >/dev/null 2>&1; then
        return 0
    fi

    # prefer curl but fall back to wget
    # Prefer CI-provided Arch (Arch or ARCH env) to avoid exec-format mismatches
    ARCH_SUFFIX="x86_64"
    if [ -n "${Arch:-}" ] || [ -n "${ARCH:-}" ]; then
        _arch_env="${Arch:-${ARCH:-}}"
        case "$_arch_env" in
            arm64|aarch64) ARCH_SUFFIX="aarch64" ;;
            x64|amd64|x86_64) ARCH_SUFFIX="x86_64" ;;
            *) ARCH_SUFFIX="x86_64" ;;
        esac
    else
        case "$(uname -m)" in
            aarch64|arm64) ARCH_SUFFIX="aarch64" ;;
            x86_64|amd64) ARCH_SUFFIX="x86_64" ;;
            *) ARCH_SUFFIX="x86_64" ;;
        esac
    fi

    urls=(
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${ARCH_SUFFIX}.AppImage"
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
    )

    # Map expected token from `file` output to the chosen ARCH_SUFFIX
    case "$ARCH_SUFFIX" in
        aarch64) expected_token="aarch64" ;;
        x86_64) expected_token="x86-64" ;;
        *) expected_token="" ;;
    esac

    for url in "${urls[@]}"; do
        tmpf=$(mktemp /tmp/appimagetool.XXXXXX) || tmpf="/tmp/appimagetool.tmp"
        if command -v curl >/dev/null 2>&1; then
            if ! curl -fSL -o "$tmpf" "$url" 2>/dev/null; then
                rm -f "$tmpf" || true
                continue
            fi
        else
            if ! wget -q -O "$tmpf" "$url" 2>/dev/null; then
                rm -f "$tmpf" || true
                continue
            fi
        fi

        chmod +x "$tmpf" || true

        # Validate architecture if `file` is available
        if command -v file >/dev/null 2>&1 && [ -n "$expected_token" ]; then
            file_out=$(file -L "$tmpf" 2>/dev/null || true)
            if ! echo "$file_out" | grep -qi "$expected_token"; then
                rm -f "$tmpf" || true
                continue
            fi
        fi

        # Move into place if possible
        if mv "$tmpf" /usr/local/bin/appimagetool 2>/dev/null; then
            chmod +x /usr/local/bin/appimagetool || true
            return 0
        else
            warn "Downloaded appimagetool to $tmpf but cannot move to /usr/local/bin (permission denied). Keeping $tmpf for potential manual use."
            # keep tmp file as fallback; signal success so caller can use it
            return 0
        fi
    done

    warn "appimagetool not available and automatic download failed; AppImage creation may be skipped"
    return 1
}

# Helper: best-effort AppImage creation if appimagetool is available
create_appimage() {
    # Try to ensure appimagetool is present; if we can't get it, skip AppImage
    ensure_appimagetool || {
        warn "appimagetool unavailable; skipping AppImage creation"
        return
    }

    APPDIR=$(mktemp -d)
    trap "rm -rf '$APPDIR'" EXIT

    mkdir -p "$APPDIR/usr/bin"
    cp "target/release/$BinaryFile" "$APPDIR/usr/bin/$Binary"
    chmod +x "$APPDIR/usr/bin/$Binary"

    # Minimal .desktop (placed where AppImage tooling expects it)
    # Minimal .desktop so appimagetool can detect the AppDir
    mkdir -p "$APPDIR/usr/share/applications"
    cat > "$APPDIR/usr/share/applications/$Binary.desktop" <<EOF
[Desktop Entry]
Name=$Binary
Exec=$Binary
Icon=$Binary
Type=Application
Categories=Utility;
EOF

# Also place a top-level copy which appimagetool will detect as the main
# desktop file (some appimagetool versions require a .desktop in AppDir/).
    cp "$APPDIR/usr/share/applications/$Binary.desktop" "$APPDIR/$Binary.desktop" || true
    chmod 0644 "$APPDIR/$Binary.desktop" || true

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

    # If the repository provides AppStream metadata, include it so appimagetool
    # can embed it and avoid the AppStream warning.
    if [ -f "packaging/flatpak/kataglyphis.appdata.xml" ]; then
        mkdir -p "$APPDIR/usr/share/metainfo"
        cp "packaging/flatpak/kataglyphis.appdata.xml" "$APPDIR/usr/share/metainfo/"
        chmod 0644 "$APPDIR/usr/share/metainfo/kataglyphis.appdata.xml" || true
    fi

    out_appimage="$ArchiveDir/${Binary}-${Version//\//-}.AppImage"
    appimagetool "$APPDIR" "$out_appimage"
    info "AppImage created: $out_appimage"
}

# Helper: build a Flatpak using packaging/flatpak manifest if available
create_flatpak() {
    # Ensure flatpak-builder is available; try to install if apt-get exists
    if ! command -v flatpak-builder >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            info "flatpak-builder not found; attempting to install flatpak-builder via apt-get"
            DEBIAN_FRONTEND=noninteractive apt-get update || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends flatpak-builder || true
        fi
    fi

    if ! command -v flatpak-builder >/dev/null 2>&1; then
        warn "flatpak-builder not found; skipping Flatpak creation"
        return
    fi

    if [ ! -f "packaging/flatpak/kataglyphis.flatpak.json" ]; then
        warn "Flatpak manifest packaging/flatpak/kataglyphis.flatpak.json not found; skipping Flatpak"
        return
    fi

    mkdir -p packaging/flatpak/build-dir
    # Copy the release binary and desktop into the build-dir under the
    # 'files' layout so the manifest can refer to them as files/bin/... and
    # files/share/....
    mkdir -p packaging/flatpak/build-dir/files/bin
    mkdir -p packaging/flatpak/build-dir/files/share/applications
    if [ -f "target/release/$BinaryFile" ]; then
        cp "target/release/$BinaryFile" "packaging/flatpak/build-dir/files/bin/$BinaryFile" || true
        chmod +x "packaging/flatpak/build-dir/files/bin/$BinaryFile" || true
    else
        warn "Release binary target/release/$BinaryFile not found; Flatpak build may fail"
    fi
    if [ -f "packaging/flatpak/kataglyphis.desktop" ]; then
        cp "packaging/flatpak/kataglyphis.desktop" packaging/flatpak/build-dir/files/share/applications/kataglyphis.desktop || true
    fi

    # Run flatpak-builder to populate a local repo
    # Ensure common runtime/sdk are available. Many manifests target a
    # specific org.freedesktop.Sdk / org.freedesktop.Platform (e.g. 24.08).
    # Add Flathub remote if missing and attempt to install the SDK+Platform so
    # flatpak-builder can initialize without failing on missing sdks.
    SDK_VER="24.08"
    if ! flatpak remote-list | grep -q '^flathub'; then
        info "Adding Flathub remote for Flatpak SDK/Platform retrieval"
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    fi
    # Try installing both the SDK and Platform (system-wide when possible).
    if ! flatpak --version >/dev/null 2>&1; then
        warn "flatpak not available; cannot attempt to install SDK/Platform"
    else
        info "Ensuring Flatpak SDK/Platform ${SDK_VER} are installed (may take some time)"
        # Prefer system installation if running as root, otherwise user
        if [ "$(id -u)" -eq 0 ]; then
            flatpak install -y --system flathub org.freedesktop.Sdk//${SDK_VER} org.freedesktop.Platform//${SDK_VER} || true
        else
            flatpak install -y --user flathub org.freedesktop.Sdk//${SDK_VER} org.freedesktop.Platform//${SDK_VER} || true
        fi
    fi

    flatpak-builder --force-clean --repo=packaging/flatpak/repo packaging/flatpak/build-dir packaging/flatpak/kataglyphis.flatpak.json

    mkdir -p "$ArchiveDir"
    repo_dir="packaging/flatpak/repo"
    if [ -d "$repo_dir" ]; then
        bundle_name="$ArchiveDir/kataglyphis.flatpak"
        # Use Version if provided, otherwise default to 1.0
        ver="${Version:-1.0}"
        # The application id is usually defined in the manifest; fall back to a sensible default
        app_id="io.kataglyphis.Kataglyphis"
        if flatpak build-bundle "$repo_dir" "$bundle_name" "$app_id" "$ver"; then
            info "Flatpak bundle created: $bundle_name"
        else
            # Non-fatal: some flatpak-builder versions may return a non-zero
            # exit code when pruning refs even though the bundle was written.
            # Log a warning and continue so CI doesn't fail on this transient
            # repository pruning issue. Users should verify the bundle exists
            # at $bundle_name when troubleshooting.
            warn "flatpak build-bundle failed; continuing. Bundle may still be at: $bundle_name"
        fi
    else
        warn "Flatpak repo not found after build; skipping bundle creation"
    fi
}

# If PACKAGE_TYPES includes additional package types, create them.
# Note: the tarball is always created above, so treat tar/gz/tgz as no-op
IFS="," read -r -a types <<< "$PackageTypes"
for t in "${types[@]}"; do
    case "$t" in
        tar|gz|tgz)
            # tar archive already created earlier in the script
            ;;
        deb)
            info "Requested .deb packaging"
            create_deb
            ;;
        appimage|AppImage)
            info "Requested AppImage packaging"
            create_appimage
            ;;
        flatpak|Flatpak)
            # If the repository provides a Flatpak manifest, run the helper to
            # create a Flatpak; otherwise warn like before.
            if [ -f "packaging/flatpak/kataglyphis.flatpak.json" ]; then
                info "Requested Flatpak packaging"
                create_flatpak
            else
                warn "Flatpak packaging requested but not automated by this script. To create a Flatpak you should add a build manifest and use flatpak-builder in CI. See: https://docs.flatpak.org/en/latest/first-build.html"
            fi
            ;;
        *)
            warn "Unknown package type requested: $t"
            ;;
    esac
done
