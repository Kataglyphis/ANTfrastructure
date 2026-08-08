#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING_DEPS_MODE="${PACKAGING_DEPS_MODE:-required}"
INSTALL_FLATPAK_RUNTIMES="${INSTALL_FLATPAK_RUNTIMES:-false}"
PACKAGING_DEPS_COMMAND="${PACKAGING_DEPS_COMMAND:-all}"

# common.sh is a hard dependency: it provides download_verified_file,
# apt_has_package and the logging helpers used throughout this script. Fail
# early with a clear message instead of dying mid-flight on "command not found".
# Probe the baked container layout (/opt/scripts/core) before the repo layout
# (../01-core), matching install-deps-preamble.sh — this script is baked into
# the toolchain image where 01-core lives at /opt/scripts/core, not ../01-core.
CORE_DIR=""
for _candidate in "/opt/scripts/core" "$SCRIPT_DIR/../01-core"; do
    if [ -f "${_candidate}/common.sh" ]; then
        CORE_DIR="${_candidate}"
        break
    fi
done
if [ -z "${CORE_DIR}" ]; then
    echo "[ERROR] packaging-deps.sh requires common.sh (download_verified_file, apt_has_package, logging) in /opt/scripts/core or $SCRIPT_DIR/../01-core; not found" >&2
    exit 1
fi
# shellcheck disable=SC1090,SC1091
source "${CORE_DIR}/common.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${CORE_DIR}/package-lists.sh" ] && source "${CORE_DIR}/package-lists.sh"

# logging.sh (via common.sh) provides info/warn but only the exiting `err`;
# this script needs a non-exiting error logger for its usage/arg handling.
error() { printf '[ERROR] %s\n' "$*" >&2; }

# ── Cleanup trap ───────────────────────────────────────────────────────

CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        if [ -f "$f" ]; then rm -f "$f"; fi
    done
}
trap cleanup EXIT

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
    local -a pkgs=()
    local install_status=0

    case "${PACKAGING_DEPS_SKIP_APT_INSTALL:-false}" in
        1|true|TRUE|yes|YES)
        info "Skipping apt packaging prerequisites because PACKAGING_DEPS_SKIP_APT_INSTALL=${PACKAGING_DEPS_SKIP_APT_INSTALL}"
        return 0
        ;;
    esac

    if declare -F packaging_prerequisite_packages >/dev/null 2>&1; then
        packaging_prerequisite_packages pkgs
    else
        pkgs=(
            ca-certificates curl wget xz-utils
            dpkg
            libfuse3-3
            flatpak flatpak-builder
            elfutils
            dbus-user-session
            build-essential appstream apt-utils
        )

        if apt_has_package libfuse2; then
            pkgs+=(libfuse2)
        elif apt_has_package libfuse2t64; then
            pkgs+=(libfuse2t64)
        fi
    fi

    info "Installing packaging prerequisites"
    info "Updating apt index"
    try_or_sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    try_or_sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "${pkgs[@]}" || install_status=$?

    if [ "${install_status}" -ne 0 ]; then
        return "${install_status}"
    fi

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
    download_verified_file "$url" "$sha256" "$tmpfile"

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

ensure_appimagetool_if_supported() {
    if ensure_appimagetool; then
        return 0
    fi

    case "$(uname -m)" in
        riscv64|riscv64gc)
            warn "Skipping appimagetool on unsupported architecture $(uname -m)"
            return 0
            ;;
    esac

    return 1
}

# ── Flatpak Runtime/SDK installation ──────────────────────────────────

install_flatpak_runtime() {
    if ! command -v flatpak >/dev/null 2>&1; then
        warn "flatpak not found; skipping runtime/SDK installation"
        return 1
    fi

    # Overridable via versions.env (FLATPAK_RUNTIME_VERSION); was the last
    # hardcoded version literal in the packaging lane.
    local runtime_version="${FLATPAK_RUNTIME_VERSION:-24.08}"

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

usage() {
    cat <<'EOF'
Usage: packaging-deps.sh [command]

Commands:
  all                 Install packaging apt deps and appimagetool; optionally Flatpak runtimes
  apt                 Install only apt-based packaging prerequisites
  appimagetool        Install only appimagetool
  flatpak-runtime     Install only Flatpak runtime and SDK
EOF
}

run_apt_step_if_available() {
    if command -v apt-get >/dev/null 2>&1; then
        run_step "apt-based packaging dependency installation" install_apt_deps
    else
        warn "apt-get not found; skipping apt-based dependency installation"
    fi
}

run_requested_command() {
    case "${PACKAGING_DEPS_COMMAND}" in
        all)
            run_apt_step_if_available
            case "${INSTALL_FLATPAK_RUNTIMES}" in
                1|true|TRUE|yes|YES)
                    run_step "Flatpak runtime installation" install_flatpak_runtime
                    ;;
            esac
            run_step "appimagetool installation" ensure_appimagetool_if_supported
            ;;
        apt)
            run_apt_step_if_available
            ;;
        appimagetool)
            run_step "appimagetool installation" ensure_appimagetool
            ;;
        flatpak-runtime)
            run_step "Flatpak runtime installation" install_flatpak_runtime
            ;;
        -h|--help)
            usage
            return 0
            ;;
        *)
            error "Unknown packaging-deps command: ${PACKAGING_DEPS_COMMAND}"
            return 1
            ;;
    esac
}

main() {
    if [ "$#" -gt 0 ]; then
        PACKAGING_DEPS_COMMAND="$1"
        shift
    fi

    if [ "$#" -gt 0 ]; then
        error "Unknown extra arguments: $*"
        return 1
    fi

    info "Running packaging dependency preflight (command=${PACKAGING_DEPS_COMMAND}, mode=${PACKAGING_DEPS_MODE}, install_flatpak_runtimes=${INSTALL_FLATPAK_RUNTIMES})"
    run_requested_command
    info "Packaging dependency preflight complete"
}

main "$@"
