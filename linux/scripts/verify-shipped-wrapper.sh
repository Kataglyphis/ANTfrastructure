#!/usr/bin/env bash
# A pushed, smoke-green wrapper can still carry a prior run's bytes, so the shipped rootfs is checked against versions.env toggles.
# Usage: verify-shipped-wrapper.sh <image-ref> <arch>; env NERDCTL_BIN, VERSIONS_ENV, WRAPPER_CONTENT_GATE=0 (advisory)
set -euo pipefail

_ref="${1:-}"
_arch="${2:-?}"
[ -n "${_ref}" ] || { echo "[wrapper-gate] usage: $0 <image-ref> <arch>" >&2; exit 2; }

_nerdctl="${NERDCTL_BIN:-nerdctl}"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_versions="${VERSIONS_ENV:-${_here}/01-core/versions.env}"

_soft="${WRAPPER_CONTENT_GATE:-1}"   # 1 = enforce; 0 = advisory-only

# _toggle <KEY>: a bare value from versions.env without sourcing it, "" if absent.
_toggle() {
  local key="$1"
  [ -f "${_versions}" ] || { printf ''; return; }
  sed -n "s/^${key}=\([^ #]*\).*/\1/p" "${_versions}" | tail -1
}

# platform.sh has no top-level statements, so sourcing it for is_truthy is side-effect-free.
# shellcheck disable=SC1091
source "${_here}/01-core/platform.sh"

# List the shipped rootfs by name only, so foreign arches need no emulation
_listing="$(mktemp)"
trap 'rm -f "${_listing}"; [ -n "${_cid:-}" ] && "${_nerdctl}" rm "${_cid}" >/dev/null 2>&1 || true' EXIT

# Pull only if missing: re-pulling would re-point the tag at the published image and mask staleness.
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

# 1) ffmpeg must be intact whatever the toggles.
if _present 'opt/ffmpeg/lib/libavcodec\.so'; then _hard 0 "ffmpeg present (libavcodec.so*)"
else _hard 1 "ffmpeg MISSING (no opt/ffmpeg/lib/libavcodec.so*)"; fi

# 2) libtensorflow presence must match FFMPEG_ENABLE_TF, the clearest stale-bytes signal.
_tf="$(_toggle FFMPEG_ENABLE_TF)"
if is_truthy "${_tf}"; then
  if _present 'opt/ffmpeg/lib/libtensorflow\.so'; then _hard 0 "FFMPEG_ENABLE_TF=${_tf}: libtensorflow present (as expected)"
  else _hard 1 "FFMPEG_ENABLE_TF=${_tf} but libtensorflow.so* is ABSENT"; fi
else
  if _present 'opt/ffmpeg/lib/libtensorflow\.so'; then _hard 1 "FFMPEG_ENABLE_TF=${_tf:-0} (off) but libtensorflow.so* is PRESENT — STALE wrapper? (RTCACHE3)"
  else _hard 0 "FFMPEG_ENABLE_TF=${_tf:-0} (off): libtensorflow absent (as expected)"; fi
fi

# 3) onnxruntime must be present; the pattern is broad because its path varies by layout.
if _present 'onnxruntime.*\.so|libonnxruntime'; then _hard 0 "onnxruntime present"
else _hard 1 "onnxruntime MISSING — no onnxruntime.so/libonnxruntime in listing"; fi

# 4) Advisory: libx265 may be linked statically into libavcodec, so absence proves nothing.
_x265="$(_toggle FFMPEG_ENABLE_X265)"
if is_truthy "${_x265}"; then
  if _present 'libx265\.so'; then _advise "FFMPEG_ENABLE_X265=${_x265}: libx265.so present"
  else _advise "FFMPEG_ENABLE_X265=${_x265}: no shared libx265.so (likely static — OK)"; fi
fi

# 5) A .symtab surviving in libavcodec means the AP4 strip regressed; a failed extraction is only advisory.
_avc_path="$(grep -E 'opt/ffmpeg/lib/libavcodec\.so\.[0-9]+\.[0-9]+\.[0-9]+$' "${_listing}" | head -1 || true)"
if [ -n "${_avc_path}" ] && command -v readelf >/dev/null 2>&1; then
  _xdir="$(mktemp -d)"
  # pipefail off: tar --occurrence=1 exits early and SIGPIPEs the exporter, so only the extracted file is the verdict.
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
  if is_truthy "${_soft}"; then
    echo "[wrapper-gate] FAIL (${_arch}): shipped content does not match build toggles — see above. (WRAPPER_CONTENT_GATE=0 to make advisory.)" >&2
    exit 1
  fi
  echo "[wrapper-gate] WARN (${_arch}): content mismatch, but WRAPPER_CONTENT_GATE=0 → advisory only." >&2
  exit 0
fi
echo "[wrapper-gate] PASS (${_arch}): shipped content matches build toggles."
exit 0
