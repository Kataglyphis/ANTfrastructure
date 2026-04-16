#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared helpers if available

[ -f "$SCRIPT_DIR/../01-core/common.sh" ] && source "$SCRIPT_DIR/../01-core/common.sh"
[ -f "$SCRIPT_DIR/../01-core/logging.sh" ] && source "$SCRIPT_DIR/../01-core/logging.sh"

# ── Fallback logging (if sourced files are missing) ────────────────────

declare -F info >/dev/null 2>&1 || info()  { printf '[INFO]  %s\n' "$*"; }
declare -F warn >/dev/null 2>&1 || warn()  { printf '[WARN]  %s\n' "$*" >&2; }
declare -F error >/dev/null 2>&1 || error() { printf '[ERROR] %s\n' "$*" >&2; }

# ── Cleanup trap ───────────────────────────────────────────────────────

CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        if [ -f "$f" ]; then rm -f "$f"; fi
    done
}
trap cleanup EXIT

# ── Helper: portable download ──────────────────────────────────────────

download() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$dest" "$url"
    else
        warn "Neither curl nor wget available"
        return 1
    fi
}

# ── Helper: run a command, retry with sudo on failure ──────────────────

try_or_sudo() {
    if "$@" 2>/dev/null; then
        return 0
    elif command -v sudo >/dev/null 2>&1; then
        info "Retrying with sudo: $1"
        sudo "$@"
    else
        warn "Command failed and sudo unavailable: $*"
        return 1
    fi
}

# ── APT dependency installation ────────────────────────────────────────

install_apt_deps() {
    local -a pkgs=(
        ca-certificates curl wget xz-utils
        dpkg
        libfuse2 libfuse3-3
        flatpak flatpak-builder
        elfutils
        dbus-user-session
        build-essential appstream apt-utils
    )

    info "Updating apt index (best-effort)"
    if ! try_or_sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        warn "apt-get update failed; trying install anyway"
    fi

    info "Installing packaging prerequisites (best-effort)"
    if try_or_sudo env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y --no-install-recommends "${pkgs[@]}"; then
        info "Packaging prerequisites installed"
        
        info "Adding flathub remote and installing flatpak runtimes"
        try_or_sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
        try_or_sudo flatpak install -y flathub org.freedesktop.Sdk//24.08 || true
        try_or_sudo flatpak install -y flathub org.freedesktop.Platform//24.08 || true
    else
        warn "Could not install all packaging prerequisites; continuing"
    fi
}

# ── appimagetool provisioning ─────────────────────────────────────────

ensure_appimagetool() {
    if command -v appimagetool >/dev/null 2>&1; then
        info "appimagetool already present: $(command -v appimagetool)"
        return 0
    fi

    local arch asset url tmpfile
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)   asset="appimagetool-x86_64.AppImage"  ;;
        aarch64|arm64)   asset="appimagetool-aarch64.AppImage" ;;
        armv7l)          asset="appimagetool-armhf.AppImage"   ;;
        i686)            asset="appimagetool-i686.AppImage"    ;;
        *)
            warn "Unsupported architecture '$arch' for appimagetool"
            return 1
            ;;
    esac

    # Use the AppImage appimagetool continuous release tag (stable asset URL).
    # The workflow previously used the 'AppImageKit/releases/latest' path which
    # started returning 404s; point to the continuous tag on the appimagetool
    # repo which contains the up-to-date assets we need.
    url="https://github.com/AppImage/appimagetool/releases/download/continuous/$asset"
    tmpfile="$(mktemp /tmp/appimagetool.XXXXXX)"
    CLEANUP_FILES+=("$tmpfile")

    info "Downloading appimagetool from $url"
    if ! download "$url" "$tmpfile"; then
        warn "Failed to download appimagetool"
        return 1
    fi

    chmod +x "$tmpfile"

    # Install to first writable location
    local dest=""
    if [ -w "/usr/local/bin" ]; then
        dest="/usr/local/bin/appimagetool"
        mv "$tmpfile" "$dest"
    elif command -v sudo >/dev/null 2>&1; then
        dest="/usr/local/bin/appimagetool"
        sudo mv "$tmpfile" "$dest"
    else
        mkdir -p "$HOME/.local/bin"
        dest="$HOME/.local/bin/appimagetool"
        mv "$tmpfile" "$dest"
        export PATH="$HOME/.local/bin:$PATH"
    fi

    if ! command -v appimagetool >/dev/null 2>&1; then
        warn "appimagetool installed to $dest but not found in PATH"
        return 1
    fi

    info "appimagetool is now available: $dest"
}

# ── Flatpak Runtime/SDK installation ──────────────────────────────────

install_flatpak_runtime() {
    if ! command -v flatpak >/dev/null 2>&1; then
        warn "flatpak not found; skipping runtime/SDK installation"
        return 1
    fi

    local runtime_version="24.08"

    info "Adding Flathub repository (if not present)"
    if ! flatpak remote-list | grep -q flathub; then
        if ! try_or_sudo flatpak remote-add --if-not-exists flathub \
                https://dl.flathub.org/repo/flathub.flatpakrepo; then
            warn "Failed to add Flathub repository"
            return 1
        fi
    fi

    info "Installing Freedesktop Platform runtime $runtime_version"
    if ! try_or_sudo flatpak install -y --noninteractive flathub \
            org.freedesktop.Platform//"$runtime_version"; then
        warn "Failed to install org.freedesktop.Platform//$runtime_version"
    fi

    info "Installing Freedesktop SDK $runtime_version"
    if ! try_or_sudo flatpak install -y --noninteractive flathub \
            org.freedesktop.Sdk//"$runtime_version"; then
        warn "Failed to install org.freedesktop.Sdk//$runtime_version"
    fi

    info "Flatpak runtime/SDK installation complete"
}

# ── Main ───────────────────────────────────────────────────────────────

info "Running packaging dependency preflight (best-effort)"

if command -v apt-get >/dev/null 2>&1; then
    install_apt_deps || true
else
    warn "apt-get not found; skipping apt-based dependency installation"
fi

install_flatpak_runtime || true

ensure_appimagetool || true

info "Packaging dependency preflight complete"