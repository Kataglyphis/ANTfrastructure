#!/usr/bin/env bash
# FFmpeg TF-probe extra-flags contract (backlog 2026-08-10 T3).
#
# THE contract: ffmpeg_probe_libtensorflow must NEVER put an arch library
# (-ltensorflow) into _FFMPEG_TF_EXTRA_LIBS. Those flags land in FFmpeg's
# GLOBAL --extra-libs, and configure validates --extra-* by compiling AND
# EXECUTING a trivial test binary — with -ltensorflow global, that binary
# NEEDs libtensorflow.so.2 and dies at load (SDK lib dir is link-path only),
# failing configure ~4s in. This exact regression shipped on 2026-08-10 and
# cost a media-stage relaunch; the fix mirrors the ONNX probe: -lstdc++ only,
# plus LD_LIBRARY_PATH so executed checks can load the .so. A future "fix the
# bare require properly" edit re-adding -ltensorflow is precisely how this
# comes back — surfacing only hours into a rebuild. Both probe paths pinned.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
DNN="${TESTS_DIR}/../03-media/build/ffmpeg/ffmpeg-dnn-backends.sh"

t_case "ffmpeg-dnn-backends.sh exists and parses"
t_assert_ok test -f "${DNN}"
t_assert_ok bash -n "${DNN}"

# Fake SDK layout so ensure_tensorflow_c_sdk short-circuits (cached-SDK check).
_sdk="$(mktemp -d)"
mkdir -p "${_sdk}/tensorflow-c/lib" "${_sdk}/tensorflow-c/include/tensorflow/c"
touch "${_sdk}/tensorflow-c/lib/libtensorflow.so" \
      "${_sdk}/tensorflow-c/include/tensorflow/c/c_api.h"

# Drive one probe path in a child bash; print the three exported flag vars.
#   $1 = rc of ffmpeg_probe_pkg_config_feature (0 = pkg-config path,
#        1 = fall through to the synth-pkgconfig path)
_run_probe() {
  bash -c "
    set -euo pipefail
    FFMPEG_SDK_CACHE='${_sdk}'
    ffmpeg_probe_pkg_config_feature() { return $1; }
    ffmpeg_enable_via_synth_pkgconfig() { return 0; }
    source '${DNN}'
    ffmpeg_probe_libtensorflow >/dev/null
    printf '%s|%s|%s|%s' \
      \"\${_FFMPEG_TF_EXTRA_CFLAGS:-}\" \"\${_FFMPEG_TF_EXTRA_LDFLAGS:-}\" \
      \"\${_FFMPEG_TF_EXTRA_LIBS:-}\" \"\${LD_LIBRARY_PATH:-}\"
  "
}

for _path in 0 1; do
  _label="pkg-config"; [ "${_path}" = "1" ] && _label="synth-pkgconfig"
  t_case "TF probe (${_label} path) runs to success"
  _out="$(_run_probe "${_path}")"
  t_assert_ok test -n "${_out}"
  IFS='|' read -r _cflags _ldflags _libs _ldpath <<< "${_out}"

  t_case "TF probe (${_label} path): _FFMPEG_TF_EXTRA_LIBS is exactly -lstdc++"
  t_assert_eq "-lstdc++" "${_libs}" "arch libs in the GLOBAL --extra-libs kill FFmpeg's executed sanity check"

  t_case "TF probe (${_label} path): no -ltensorflow anywhere in the extra flags"
  _flags_joined="${_cflags} ${_ldflags} ${_libs}"
  t_assert_ok bash -c "case '${_flags_joined}' in *-ltensorflow*) exit 1;; *) exit 0;; esac"

  t_case "TF probe (${_label} path): cflags/ldflags point into the SDK cache"
  t_assert_eq "-I${_sdk}/tensorflow-c/include" "${_cflags}"
  t_assert_eq "-L${_sdk}/tensorflow-c/lib" "${_ldflags}"

  t_case "TF probe (${_label} path): SDK lib dir exported on LD_LIBRARY_PATH (executed checks must load the .so)"
  t_assert_contains "${_ldpath}" "${_sdk}/tensorflow-c/lib"
done

rm -rf "${_sdk}"

# ---------------------------------------------------------------------------
# FFMPEG_ENABLE_TF gate (backlog S2). The TF C SDK adds ~500 MB to the amd64
# image for one OPTIONAL DNN backend, so it is gated OFF by default, mirroring
# FFMPEG_ENABLE_X265. Assert: (1) the default is OFF in versions.env + the
# Dockerfile ARG, (2) the configure call site is gated by is_truthy, (3) the
# SDK-download function honors the gate and skips when off, (4) ONNX Runtime is
# NOT gated (stays always-on).
BUILD="${TESTS_DIR}/../03-media/build/ffmpeg/build-ffmpeg.sh"
VERSIONS="${TESTS_DIR}/../01-core/versions.env"
DOCKERFILE="${TESTS_DIR}/../../Dockerfile.media"

t_case "versions.env defines FFMPEG_ENABLE_TF and it defaults OFF (0)"
t_assert_ok grep -qE '^FFMPEG_ENABLE_TF=0$' "${VERSIONS}"

t_case "Dockerfile.media ARG FFMPEG_ENABLE_TF defaults OFF (0), matching versions.env"
t_assert_ok grep -qE '^ARG FFMPEG_ENABLE_TF=0$' "${DOCKERFILE}"

t_case "build-ffmpeg.sh gates --enable-libtensorflow behind is_truthy FFMPEG_ENABLE_TF"
t_assert_ok grep -qE 'is_truthy "\$\{FFMPEG_ENABLE_TF:-0\}" && ffmpeg_probe_libtensorflow' "${BUILD}"

t_case "ONNX Runtime backend is NOT gated by any FFMPEG_ENABLE toggle (stays always-on)"
# The libonnxruntime enable must be reached unconditionally in the dnn-backend
# probe — no FFMPEG_ENABLE_* guard on its `if ffmpeg_probe_libonnxruntime` line.
t_assert_ok grep -qE '^\s*if ffmpeg_probe_libonnxruntime; then' "${BUILD}"

# Drive ensure_tensorflow_c_sdk with the gate toggled, an EMPTY cache (so the
# cached-SDK short-circuit does not pre-empt the gate), and download stubbed to
# fail (never touch the network). is_truthy is provided with platform.sh
# semantics — the real function is in common.sh, not sourced in this unit test.
_run_ensure() {
  # $1 = FFMPEG_ENABLE_TF value ("" = unset -> default off)
  local _cache; _cache="$(mktemp -d)"
  bash -c "
    set -uo pipefail
    is_truthy() { case \"\${1:-}\" in 1|true|TRUE|yes|YES|on|ON) return 0;; *) return 1;; esac; }
    download_file() { return 1; }
    download_verified_file() { return 1; }
    FFMPEG_SDK_CACHE='${_cache}'
    ${1:+FFMPEG_ENABLE_TF='$1'}
    source '${DNN}'
    ensure_tensorflow_c_sdk 2>&1 || true
  "
  rm -rf "${_cache}"
}

t_case "ensure_tensorflow_c_sdk: gate FIRES when FFMPEG_ENABLE_TF unset (default off)"
_off_default="$(_run_ensure "")"
t_assert_contains "${_off_default}" "FFMPEG_ENABLE_TF is off"

t_case "ensure_tensorflow_c_sdk: gate FIRES when FFMPEG_ENABLE_TF=0"
_off_explicit="$(_run_ensure "0")"
t_assert_contains "${_off_explicit}" "FFMPEG_ENABLE_TF is off"

t_case "ensure_tensorflow_c_sdk: gate does NOT fire when FFMPEG_ENABLE_TF=1 (download path reached)"
_on="$(_run_ensure "1")"
t_assert_ok bash -c "case '${_on}' in *'FFMPEG_ENABLE_TF is off'*) exit 1;; *) exit 0;; esac"

t_summary
