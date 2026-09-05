#!/usr/bin/env bash
# ensure_appimagetool's install mode. appimagetool is an AppImage: it reads
# /proc/self/exe for its own squashfs offset, so executable-but-unreadable is a
# tool that works for root and for nobody else.
# docs/consumer-image-contract.md#the-contract
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../02-toolchain/packaging-deps.sh"

t_case "the downloaded tool is made readable, not merely executable"
# mktemp creates 0600; `chmod +x` on that yields 0711, which travels through mv.
_tmp="$(mktemp)"; chmod 0600 "${_tmp}"
chmod +x "${_tmp}"
t_assert_eq "711" "$(stat -c '%a' "${_tmp}")" "this is what the old line produced"
chmod 0755 "${_tmp}"
t_assert_eq "755" "$(stat -c '%a' "${_tmp}")" "and this is what a consumer can read"
rm -f "${_tmp}"

t_case "ensure_appimagetool sets an explicit mode"
_src="$(t_fn_src "${SUBJECT}" ensure_appimagetool)"
t_assert_contains "${_src}" 'chmod 0755 "$tmpfile"' \
  "an explicit mode, because the umask and mktemp decide the rest otherwise"
t_assert_eq 0 "$(printf '%s\n' "${_src}" | grep -c 'chmod +x "\$tmpfile"')" \
  "chmod +x preserves mktemp's 0600 for group and other"

# ---------------------------------------------------------------------------
# The AppImage runtime: taken from appimagetool's own bytes, never downloaded.
# docs/consumer-image-contract.md#the-appimage-runtime-ships-with-the-tool

t_case "the runtime stager is reached from BOTH of ensure_appimagetool's success paths"
_ea="$(t_fn_src "${SUBJECT}" ensure_appimagetool)"
t_assert_eq "2" "$(printf '%s\n' "${_ea}" | grep -c 'ensure_appimagetool_runtime')" \
  "already-present and just-installed both end with a staged runtime, or one path ships without it"
t_assert_contains "${_ea}" 'info "appimagetool already present' \
  "the early-present arm is the one a cached layer takes, and it is the easy one to forget"

# Drive the real function with a fake appimagetool whose first N bytes ARE the
# runtime, in a sandbox HOME/skel — no network, no /etc write.
_pd_stage() {
  local offset="$1" home="$2"
  local tool="${_PD_BIN}/appimagetool"
  { printf 'RUNTIMEBYTES'; printf 'PAYLOADPAYLOAD'; } > "${tool}"
  chmod 0755 "${tool}"
  cat > "${_PD_BIN}/offsetwrap" <<WRAP
#!/usr/bin/env bash
[ "\$1" = "--appimage-offset" ] && { printf '%s\n' "${offset}"; exit 0; }
exit 1
WRAP
  chmod 0755 "${_PD_BIN}/offsetwrap"
  (
    set -uo pipefail
    eval "$(t_fn_src "${SUBJECT}" ensure_appimagetool_runtime)"
    info() { printf 'INFO %s\n' "$*"; }
    warn() { printf 'WARN %s\n' "$*"; }
    # The stager reads the tool it finds on PATH and asks IT for the offset.
    command() {
      if [ "$1" = "-v" ] && [ "$2" = "appimagetool" ]; then printf '%s\n' "${_PD_BIN}/offsetwrap"; return 0; fi
      builtin command "$@"
    }
    HOME="${home}"
    ensure_appimagetool_runtime
    printf 'EXIT %s\n' "$?"
  ) 2>&1
}

_PD_TMP="$(mktemp -d)"; _PD_BIN="${_PD_TMP}/bin"; mkdir -p "${_PD_BIN}"
trap 'rm -rf "${_PD_TMP}"' EXIT

t_case "a non-numeric offset warns and stages nothing, rather than truncating garbage"
_out="$(_pd_stage "not-a-number" "${_PD_TMP}/h1")"
t_assert_contains "${_out}" "WARN " "an unreadable offset must say so"
t_assert_contains "${_out}" "EXIT 0" "and must stay non-fatal: a missing runtime costs one download"

t_case "an empty offset is treated the same as a non-numeric one"
_out="$(_pd_stage "" "${_PD_TMP}/h2")"
t_assert_contains "${_out}" "WARN " "'' must not slip through the [!0-9] arm"
t_assert_contains "${_out}" "EXIT 0"

t_case "the runtime is cut from the tool's own bytes, at the offset it reports"
_src="$(t_fn_src "${SUBJECT}" ensure_appimagetool_runtime)"
t_assert_contains "${_src}" 'head -c "${offset}" "${tool}"' \
  "the runtime is the tool's own prefix -- a download here would need a second pin"
t_assert_eq "0" "$(printf '%s\n' "${_src}" | grep -c 'curl\|wget\|download_')" \
  "upstream publishes the runtime only under the moving 'continuous' tag; fetching it is the TS1 trap"

t_case "it is staged for the runtime user as well as the build user"
t_assert_contains "${_src}" '/etc/skel/.local/share/appimagekit' \
  "the runtime user is created later and inherits /etc/skel"
t_assert_contains "${_src}" '${HOME:-/root}/.local/share/appimagekit' \
  "and the user running the packaging step now"
t_assert_contains "${_src}" 'runtime-${arch_name}' \
  "appimagetool looks the runtime up by uname -m, so the name is not decoration"

t_case "no appimagetool is a no-op, not a failure"
t_assert_contains "${_src}" 'command -v appimagetool 2>/dev/null)" || return 0' \
  "riscv64 has no upstream appimagetool; that must not fail a toolchain stage"

# ---------------------------------------------------------------------------
# The Flatpak runtime set. docs/consumer-image-contract.md#the-flatpak-runtimes-ship-with-the-image

t_case "all seven refs a Flatpak build resolves are installed, not just two"
_refs="$( eval "$(t_fn_src "${SUBJECT}" _flatpak_refs)"; _flatpak_refs 24.08 2.5.1 )"
t_assert_eq "7" "$(printf '%s\n' "${_refs}" | grep -c .)" \
  "five of the seven used to be left to every consumer run -- ~1.9 GB per build"
t_assert_eq "2" "$(printf '%s\n' "${_refs}" | grep -c 'GL\.default')" \
  "the base branch and its 'extra' sibling are SEPARATE refs; resolving one still fetches the other"
t_assert_contains "${_refs}" "org.freedesktop.Platform.GL.default//24.08extra" \
  "the extra sibling is a branch suffix, not its own version"
t_assert_contains "${_refs}" "org.freedesktop.Platform.openh264//2.5.1" \
  "openh264 is pinned by FLATPAK_OPENH264_VERSION, not by the runtime version"
t_assert_eq "0" "$(printf '%s\n' "${_refs}" | grep -c '//$\|//extra')" \
  "an unset version must not produce a ref with an empty branch"

t_case "the runtimes are ON by default: the shipped image had zero refs"
t_assert_contains "$(grep -e 'INSTALL_FLATPAK_RUNTIMES=' "${SUBJECT}")" 'INSTALL_FLATPAK_RUNTIMES:-true' \
  "flatpak list --runtime returned ZERO in the shipped image; off by default is what put it there"

t_case "an arch Flathub does not build for is skipped, not retried"
_ifr="$(t_fn_src "${SUBJECT}" install_flatpak_runtime)"
t_assert_contains "${_ifr}" "x86_64|aarch64" \
  "Flathub builds these two only; anything else is a guaranteed 404"

t_summary
