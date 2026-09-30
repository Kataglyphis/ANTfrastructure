#!/usr/bin/env bash
# No -ltensorflow in FFmpeg's global --extra-libs: configure executes a test binary that cannot load it.
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

# _run_probe <0 = pkg-config path | 1 = synth-pkgconfig path>: prints the exported flag vars.
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

# FFMPEG_ENABLE_TF keeps the large, optional TF C SDK off by default; ONNX Runtime stays ungated.
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
# No FFMPEG_ENABLE_* guard may sit on the `if ffmpeg_probe_libonnxruntime` line.
t_assert_ok grep -qE '^\s*if ffmpeg_probe_libonnxruntime; then' "${BUILD}"

# An empty cache so the cached-SDK short-circuit cannot pre-empt the gate; downloads always fail.
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


# Checked statically: the NVIDIA block runs only inside a CUDA image, which the standard lane never builds.
t_case "the NVIDIA FFmpeg flags stay redistributable (no nonfree pairing)"
_FFB="${TESTS_DIR}/../03-media/build/ffmpeg/build-ffmpeg.sh"
_ff_src="$(sed 's/#.*$//' "${_FFB}")"
t_assert_eq "0" "$(printf '%s' "${_ff_src}" | grep -c -- '--enable-cuda-nvcc' || true)" \
  "--enable-cuda-nvcc requires --enable-nonfree, which is incompatible with --enable-gpl here"
t_assert_eq "0" "$(printf '%s' "${_ff_src}" | grep -c -- '--enable-nonfree' || true)" \
  "--enable-nonfree would make the shipped FFmpeg non-redistributable"
# The hardware codecs stay; read from a file because a `bash -c` subshell cannot see the caller's locals.
_ff_stripped="$(mktemp)"
sed 's/#.*$//' "${_FFB}" > "${_ff_stripped}"
for _flag in nvenc nvdec cuvid ffnvcodec; do
  t_assert_ok grep -q -- "--enable-${_flag}" "${_ff_stripped}"
done
rm -f "${_ff_stripped}"

t_summary
