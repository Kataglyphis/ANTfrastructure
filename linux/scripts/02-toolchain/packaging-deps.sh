#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING_DEPS_MODE="${PACKAGING_DEPS_MODE:-required}"
# On by default, or every consumer run downloads them. docs/consumer-image-contract.md#the-flatpak-runtimes-ship-with-the-image
INSTALL_FLATPAK_RUNTIMES="${INSTALL_FLATPAK_RUNTIMES:-true}"
PACKAGING_DEPS_COMMAND="${PACKAGING_DEPS_COMMAND:-all}"

# common.sh is required; probe the baked /opt/scripts/core before the repo layout.
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

# A non-exiting error logger, since logging.sh's err exits.
error() { printf '[ERROR] %s\n' "$*" >&2; }

# Cleanup trap

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

# Run a command, retrying with sudo on failure

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

# APT dependencies

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
            # libfuse3-4 after resolute's soname bump; the old name would be dropped silently.
            libfuse3-4
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

# appimagetool

# The runtime is read from the pinned tool's own bytes. docs/consumer-image-contract.md#the-appimage-runtime-ships-with-the-tool
_APPIMAGE_SQUASHFS_OFFSET_PY='
import struct, sys
d = open(sys.argv[1], "rb").read()
i = -1
while True:
    i = d.find(b"hsqs", i + 1)
    if i < 0 or i + 96 > len(d):
        sys.exit(1)
    bs, = struct.unpack_from("<I", d, i + 12)
    maj, = struct.unpack_from("<H", d, i + 28)
    if maj == 4 and 4096 <= bs <= 1048576 and (bs & (bs - 1)) == 0:
        print(i)
        break
'

ensure_appimagetool_runtime() {
    local tool offset arch_name dir
    tool="$(command -v appimagetool 2>/dev/null)" || return 0
    [ -n "${tool}" ] || return 0
    arch_name="$(uname -m)"

    # "hsqs" also occurs earlier in the ELF, so the superblock is validated, not just the magic.
    offset="$(python3 -c "${_APPIMAGE_SQUASHFS_OFFSET_PY}" "${tool}" 2>/dev/null)" || offset=""
    case "${offset}" in
        ''|*[!0-9]*)
            warn "no squashfs superblock in ${tool}; runtime-${arch_name} not staged"
            return 0
            ;;
    esac

    for dir in /etc/skel/.local/share/appimagekit "${HOME:-/root}/.local/share/appimagekit"; do
        mkdir -p "${dir}"
        head -c "${offset}" "${tool}" > "${dir}/runtime-${arch_name}"
        chmod 0755 "${dir}/runtime-${arch_name}"
    done
    info "Staged AppImage runtime-${arch_name} (${offset} bytes) from ${tool}"
}

ensure_appimagetool() {
    if command -v appimagetool >/dev/null 2>&1; then
        info "appimagetool already present: $(command -v appimagetool)"
        ensure_appimagetool_runtime
        return 0
    fi

    local arch asset url tmpfile sha256 version
    # A versioned tag, never `continuous`, which re-uploads assets in place; bump the version and all four SHAs together.
    version="${APPIMAGETOOL_VERSION:-1.9.1}"
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            asset="appimagetool-x86_64.AppImage"
            sha256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
            ;;
        aarch64|arm64)
            asset="appimagetool-aarch64.AppImage"
            sha256="f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"
            ;;
        armv7l)
            asset="appimagetool-armhf.AppImage"
            sha256="42b61cba5495d8aaf418a5c9a015a49b85ad92efabcbd3c341f1540440e4e23d"
            ;;
        i686)
            asset="appimagetool-i686.AppImage"
            sha256="7ad9ff47c203aae0149b18f6df9e3018b2e2f470ea644a0413e3ded39e9e3bdb"
            ;;
        *)
            warn "Unsupported architecture '$arch' for appimagetool"
            return 1
            ;;
    esac

    # Immutable versioned asset URL.
    url="https://github.com/AppImage/appimagetool/releases/download/${version}/$asset"
    tmpfile="$(mktemp /tmp/appimagetool.XXXXXX)"
    CLEANUP_FILES+=("$tmpfile")

    info "Downloading appimagetool from $url"
    download_verified_file "$url" "$sha256" "$tmpfile"

    # 0755, not +x over mktemp's 0600: an AppImage must read itself. docs/consumer-image-contract.md#executable-is-not-usable
    chmod 0755 "$tmpfile"

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
    ensure_appimagetool_runtime
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

# Flatpak runtime and SDK

# GL.default twice: its extra branch is a separate ref. docs/consumer-image-contract.md#the-flatpak-runtimes-ship-with-the-image
_flatpak_refs() {
    local version="$1"

    # Since 25.08 the extra branches are <ver>-extra, and the codecs ride codecs-extra; no openh264 extension is left.
    printf '%s\n' \
        "org.freedesktop.Platform//${version}" \
        "org.freedesktop.Sdk//${version}" \
        "org.freedesktop.Platform.Locale//${version}" \
        "org.freedesktop.Sdk.Locale//${version}" \
        "org.freedesktop.Platform.GL.default//${version}" \
        "org.freedesktop.Platform.GL.default//${version}-extra" \
        "org.freedesktop.Platform.codecs-extra//${version}-extra"
}

# Tells an unpublished branch from a failed payload fetch.
_flatpak_diagnose_ref() {
    local ref="$1" name branches
    name="${ref%%//*}"
    branches="$(flatpak remote-ls flathub --arch="$(uname -m)" --columns=ref 2>/dev/null \
        | grep -e "/${name}/" | sed 's#.*/##' | sort -u | tr '\n' ' ')"
    if [ -n "${branches}" ]; then
        warn "${ref}: flathub publishes ${name} for $(uname -m) at branch(es): ${branches}"
    else
        warn "${ref}: flathub lists no ${name} for $(uname -m) at all -- the ref NAME is wrong, not its branch"
    fi
}

install_flatpak_runtime() {
    if ! command -v flatpak >/dev/null 2>&1; then
        warn "flatpak not found; skipping runtime/SDK installation"
        return 1
    fi

    # Flathub builds these for x86_64 and aarch64 only; elsewhere a 404 is certain, not transient.
    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64|aarch64) ;;
        *)
            warn "Flathub publishes no freedesktop runtimes for ${machine}; skipping"
            return 0
            ;;
    esac

    local runtime_version="${FLATPAK_RUNTIME_VERSION:-26.08}"

    info "Adding Flathub repository (if not present)"
    if ! flatpak remote-list | grep -q flathub; then
        try_or_sudo flatpak remote-add --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo
    fi

    local ref failed=0 total=0
    while IFS= read -r ref; do
        [ -n "${ref}" ] || continue
        total=$((total + 1))
        info "Installing ${ref}"
        try_or_sudo flatpak install -y --noninteractive flathub "${ref}" \
            || { _flatpak_diagnose_ref "${ref}"
                 warn "${ref} did not install; consumers will fetch it per run"
                 failed=$((failed + 1)); }
    done <<EOF
$(_flatpak_refs "${runtime_version}")
EOF

    info "Flatpak runtime installation complete ($((total - failed))/${total} refs)"
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
            run_step "AppImage runtime staging" ensure_appimagetool_runtime
            ;;
        apt)
            run_apt_step_if_available
            ;;
        appimagetool)
            run_step "appimagetool installation" ensure_appimagetool
            run_step "AppImage runtime staging" ensure_appimagetool_runtime
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
