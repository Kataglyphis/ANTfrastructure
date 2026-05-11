#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING_DEPS_MODE="${PACKAGING_DEPS_MODE:-required}"
INSTALL_FLATPAK_RUNTIMES="${INSTALL_FLATPAK_RUNTIMES:-false}"

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
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$dest" "$url"
    else
        warn "Neither curl nor wget available"
        return 1
    fi
}

download_verified() {
    local url="$1" expected_sha256="$2" dest="$3"

    download "$url" "$dest"
    printf '%s  %s\n' "$expected_sha256" "$dest" | sha256sum -c - >/dev/null
}

best_effort_mode() {
    [ "${PACKAGING_DEPS_MODE}" = "best-effort" ]
}

run_step() {
    local label="$1"
    shift
    local status=0

    "$@" || status=$?
    if [ "$status" -eq 0 ]; then
        return 0
    fi

    if best_effort_mode; then
        warn "${label} failed; continuing because PACKAGING_DEPS_MODE=${PACKAGING_DEPS_MODE}"
        return 0
    fi

    return "$status"
}

apt_has_package() {
    local pkg="$1"
    apt-cache show "$pkg" >/dev/null 2>&1
}

# ── Helper: run a command, retry with sudo on failure ──────────────────

try_or_sudo() {
    local status=0

    "$@" || status=$?
    if [ "$status" -eq 0 ]; then
        return 0
    fi

    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        return "$status"
    elif command -v sudo >/dev/null 2>&1; then
        info "Retrying with sudo: $1"
        sudo "$@"
    else
        warn "Command failed and sudo unavailable: $*"
        return "$status"
    fi
}

# ── APT dependency installation ────────────────────────────────────────

install_apt_deps() {
    local -a pkgs=(
        ca-certificates curl wget xz-utils
        dpkg
        libfuse3-3
        flatpak flatpak-builder
        elfutils
        dbus-user-session
        build-essential appstream apt-utils
    )

    info "Updating apt index"
    try_or_sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq

    if apt_has_package libfuse2; then
        pkgs+=(libfuse2)
    elif apt_has_package libfuse2t64; then
        pkgs+=(libfuse2t64)
    fi

    info "Installing packaging prerequisites"
    try_or_sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "${pkgs[@]}"

    info "Packaging prerequisites installed"
}

# ── appimagetool provisioning ─────────────────────────────────────────

ensure_appimagetool() {
    if command -v appimagetool >/dev/null 2>&1; then
        info "appimagetool already present: $(command -v appimagetool)"
        return 0
    fi

    local arch asset url tmpfile sha256
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            asset="appimagetool-x86_64.AppImage"
            sha256="a6d71e2b6cd66f8e8d16c37ad164658985e0cf5fcaa950c90a482890cb9d13e0"
            ;;
        aarch64|arm64)
            asset="appimagetool-aarch64.AppImage"
            sha256="1b00524ba8c6b678dc15ef88a5c25ec24def36cdfc7e3abb32ddcd068e8007fe"
            ;;
        armv7l)
            asset="appimagetool-armhf.AppImage"
            sha256="32aeca26db15a7d029b76adb8d5836f98acbf4a37b2a3101758b094f721e4b67"
            ;;
        i686)
            asset="appimagetool-i686.AppImage"
            sha256="ba04b9ecb2869993173bd38516dbafcfbe3064aca942500e94e7a3c3c2ea578d"
            ;;
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
    download_verified "$url" "$sha256" "$tmpfile"

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
        try_or_sudo flatpak remote-add --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo
    fi

    info "Installing Freedesktop Platform runtime $runtime_version"
    try_or_sudo flatpak install -y --noninteractive flathub \
        org.freedesktop.Platform//"$runtime_version"

    info "Installing Freedesktop SDK $runtime_version"
    try_or_sudo flatpak install -y --noninteractive flathub \
        org.freedesktop.Sdk//"$runtime_version"

    info "Flatpak runtime/SDK installation complete"
}

# ── Main ───────────────────────────────────────────────────────────────

info "Running packaging dependency preflight (mode=${PACKAGING_DEPS_MODE}, install_flatpak_runtimes=${INSTALL_FLATPAK_RUNTIMES})"

if command -v apt-get >/dev/null 2>&1; then
    run_step "apt-based packaging dependency installation" install_apt_deps
else
    warn "apt-get not found; skipping apt-based dependency installation"
fi

case "${INSTALL_FLATPAK_RUNTIMES}" in
    1|true|TRUE|yes|YES)
        run_step "Flatpak runtime installation" install_flatpak_runtime
        ;;
esac

run_step "appimagetool installation" ensure_appimagetool

info "Packaging dependency preflight complete"
