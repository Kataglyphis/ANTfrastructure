#!/usr/bin/env bash
# verify-shipped-wrapper.sh — post-build CONTENT byte-gate for a runtime wrapper.
#
# WHY THIS EXISTS (RTCACHE3, 2026-08-15): a wrapper can be pushed, boot-smoke
# green, and indexed into :latest-cross while carrying STALE bytes from a prior
# run — the S2 saga shipped :latest-cross byte-identical FIVE times with every
# static gate and all smokes green, because `nerdctl build --output type=image,
# name=X` never moved the local tag off the previous image. "manifest pushed"
# must NEVER be trusted as "fresh content shipped". This gate re-derives the
# EXPECTED /opt/ffmpeg lib set from the build toggles (versions.env) and asserts
# the shipped image actually matches — the exact manual pull+grep that caught
# all five stale ships, automated.
#
# Arch-agnostic BY DESIGN: it lists the image rootfs via `nerdctl export | tar
# -t` (a file-name listing, no extraction) so it works for arm64/riscv64 wrappers
# on an amd64 host WITHOUT qemu/binfmt — unlike the boot smoke, which executes
# the foreign binary under emulation.
#
# Usage: verify-shipped-wrapper.sh <image-ref> <arch>
#   <image-ref>  a per-arch wrapper tag or digest (must be pullable / local)
#   <arch>       amd64 | arm64 | riscv64  (informational, for messages)
#
# Env:
#   NERDCTL_BIN                nerdctl executable (default: nerdctl)
#   VERSIONS_ENV               path to versions.env (default: alongside this script)
#   WRAPPER_CONTENT_GATE=0     make every mismatch advisory (warn, exit 0)
#
# Exit: 0 = all HARD assertions pass; 1 = a HARD assertion failed (or the image
# could not be listed). Advisory checks (x265, AP4 extraction-failed) only warn.
set -euo pipefail

_ref="${1:-}"
_arch="${2:-?}"
[ -n "${_ref}" ] || { echo "[wrapper-gate] usage: $0 <image-ref> <arch>" >&2; exit 2; }

_nerdctl="${NERDCTL_BIN:-nerdctl}"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_versions="${VERSIONS_ENV:-${_here}/01-core/versions.env}"

_soft="${WRAPPER_CONTENT_GATE:-1}"   # 1 = enforce; 0 = advisory-only

# Read a bare KEY=value from versions.env without sourcing the whole file
# (avoids pulling its full ARG surface into this gate). Returns "" if absent.
_toggle() {
  local key="$1"
  [ -f "${_versions}" ] || { printf ''; return; }
  sed -n "s/^${key}=\([^ #]*\).*/\1/p" "${_versions}" | tail -1
}

_is_truthy() { case "${1:-}" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac; }

# ── list the shipped rootfs (file names only, no extraction, no emulation) ──────
_listing="$(mktemp)"
trap 'rm -f "${_listing}"; [ -n "${_cid:-}" ] && "${_nerdctl}" rm "${_cid}" >/dev/null 2>&1 || true' EXIT

# Ensure present locally only if missing — never re-pull an existing tag (that
# would re-point it at the PUBLISHED image and could mask the very staleness we
# are checking for; mirrors the boot-smoke's conditional-pull fix).
if ! "${_nerdctl}" image inspect "${_ref}" >/dev/null 2>&1; then
  "${_nerdctl}" pull -q "${_ref}" >/dev/null 2>&1 || true
fi
_cid="$("${_nerdctl}" create "${_ref}" 2>/dev/null || true)"
[ -n "${_cid}" ] || { echo "[wrapper-gate] FAIL (${_arch}): cannot create container from ${_ref}" >&2; exit 1; }
if ! "${_nerdctl}" export "${_cid}" 2>/dev/null | tar -tf - > "${_listing}" 2>/dev/null; then
  echo "[wrapper-gate] FAIL (${_arch}): cannot list rootfs of ${_ref}" >&2
  exit 1
fi

_present() { grep -qE "$1" "${_listing}"; }

_hard_fail=0
_hard() {  # <ok:0|1> <message>
  if [ "$1" -eq 0 ]; then echo "  OK  $2"; else
    echo "  FAIL $2" >&2; _hard_fail=1
  fi
}
_advise() { echo "  note $1"; }

echo "[wrapper-gate] verifying shipped content of ${_ref} (${_arch})"

# 1) ffmpeg must be intact regardless of any toggle (catches a broken/empty
#    /opt/ffmpeg — the wrapper is useless without libavcodec).
if _present 'opt/ffmpeg/lib/libavcodec\.so'; then _hard 0 "ffmpeg present (libavcodec.so*)"
else _hard 1 "ffmpeg MISSING (no opt/ffmpeg/lib/libavcodec.so*)"; fi

# 2) libtensorflow presence MUST match FFMPEG_ENABLE_TF — the exact RTCACHE3/S2
#    signal. TF off (default) → the ~500MB lib must be ABSENT; TF on → present.
_tf="$(_toggle FFMPEG_ENABLE_TF)"
if _is_truthy "${_tf}"; then
  if _present 'opt/ffmpeg/lib/libtensorflow\.so'; then _hard 0 "FFMPEG_ENABLE_TF=${_tf}: libtensorflow present (as expected)"
  else _hard 1 "FFMPEG_ENABLE_TF=${_tf} but libtensorflow.so* is ABSENT"; fi
else
  if _present 'opt/ffmpeg/lib/libtensorflow\.so'; then _hard 1 "FFMPEG_ENABLE_TF=${_tf:-0} (off) but libtensorflow.so* is PRESENT — STALE wrapper? (RTCACHE3)"
  else _hard 0 "FFMPEG_ENABLE_TF=${_tf:-0} (off): libtensorflow absent (as expected)"; fi
fi

# 3) onnxruntime must be present — the image is built around ORT; its absence is
#    always a defect (LOG33 — was advisory). Path varies (opt/android/onnxruntime,
#    venv, …) but the .so pattern is broad enough to catch all layouts.
if _present 'onnxruntime.*\.so|libonnxruntime'; then _hard 0 "onnxruntime present"
else _hard 1 "onnxruntime MISSING — no onnxruntime.so/libonnxruntime in listing"; fi

# 4) Advisory: x265 toggle → libx265 (may be static-linked into libavcodec, so a
#    missing shared lib is not proof; informational only).
_x265="$(_toggle FFMPEG_ENABLE_X265)"
if _is_truthy "${_x265}"; then
  if _present 'libx265\.so'; then _advise "FFMPEG_ENABLE_X265=${_x265}: libx265.so present"
  else _advise "FFMPEG_ENABLE_X265=${_x265}: no shared libx265.so (likely static — OK)"; fi
fi

# 5) SMK2 (2026-08-17): verify the AP4 strip actually happened on a sentinel
#    lib. Extract exactly ONE real file (the versioned libavcodec) from a second
#    export stream — `--occurrence=1` lets tar stop early — and check host-side
#    with readelf (arch-agnostic on ELF sections; no emulation). A surviving
#    .symtab means the strip pass regressed. HARD when the file was extracted
#    (LOG33 — was advisory); advisory only when extraction itself failed,
#    since we cannot assert on missing evidence.
_avc_path="$(grep -E 'opt/ffmpeg/lib/libavcodec\.so\.[0-9]+\.[0-9]+\.[0-9]+$' "${_listing}" | head -1 || true)"
if [ -n "${_avc_path}" ] && command -v readelf >/dev/null 2>&1; then
  _xdir="$(mktemp -d)"
  # AP4-SIGPIPE (2026-08-23): `--occurrence=1` makes tar exit after the first
  # match, which SIGPIPEs the still-streaming exporter; under `set -o pipefail`
  # the whole pipeline then returns non-zero and this check silently reported
  # "skipped" on 3/3 arches of every ship while the gate still printed PASS.
  # Run the pipeline with pipefail OFF and let the extracted file be the sole
  # verdict — an early tar exit is the DESIGN here, not a failure.
  ( set +o pipefail
    "${_nerdctl}" export "${_cid}" 2>/dev/null \
      | tar -xf - -C "${_xdir}" --occurrence=1 "${_avc_path}" 2>/dev/null ) || true
  if [ -f "${_xdir}/${_avc_path}" ]; then
    if [ "$(readelf -S "${_xdir}/${_avc_path}" 2>/dev/null | grep -c '\.symtab')" -eq 0 ]; then
      _hard 0 "AP4 strip verified: $(basename "${_avc_path}") has no .symtab"
    else
      _hard 1 "AP4 strip NOT applied: $(basename "${_avc_path}") still carries .symtab — MEDIA_STRIP regressed?"
    fi
  else
    _advise "AP4 strip check skipped (could not extract ${_avc_path})"
  fi
  rm -rf "${_xdir}"
fi

if [ "${_hard_fail}" -ne 0 ]; then
  if _is_truthy "${_soft}"; then
    echo "[wrapper-gate] FAIL (${_arch}): shipped content does not match build toggles — see above. (WRAPPER_CONTENT_GATE=0 to make advisory.)" >&2
    exit 1
  fi
  echo "[wrapper-gate] WARN (${_arch}): content mismatch, but WRAPPER_CONTENT_GATE=0 → advisory only." >&2
  exit 0
fi
echo "[wrapper-gate] PASS (${_arch}): shipped content matches build toggles."
exit 0
