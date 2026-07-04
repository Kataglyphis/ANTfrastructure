#!/usr/bin/env bash
# ffmpeg-dnn-backends.sh - FFmpeg DNN backend probes (ONNX Runtime, TensorFlow, OpenVINO)
# Split out of build-ffmpeg.sh (pure structural refactor; no behavior change).
# Source-only helper; sourced by build-ffmpeg.sh — expects its set -euo pipefail and IFS.

ffmpeg_probe_libonnxruntime() {
    # ONNX Runtime is built into this stage at a known prefix, but its VENDOR
    # libonnxruntime.pc is unusable: it resolves via --exists yet its -I does not
    # locate the header for FFmpeg. Worse, the generic probe can now "pass" it via
    # the lenient headers-compile+empty-link fallback (our own -I/pkg-config flags
    # find the header), after which FFmpeg's own require canNOT and HARD-ABORTS the
    # whole build. So when the known install is present, go STRAIGHT to the
    # synthesized .pc (correct -I + exported PKG_CONFIG_PATH, which is exactly what
    # FFmpeg's require_pkg_config consumes) — do not trust the vendor .pc first.
    local onnx_base="/usr/local/lib/onnxruntime-cpu"
    if [ -f "${onnx_base}/lib/libonnxruntime.so" ] && [ -f "${onnx_base}/include/onnxruntime_c_api.h" ]; then
        if ffmpeg_enable_via_synth_pkgconfig "libonnxruntime" "libonnxruntime" \
            "onnxruntime_c_api.h" "OrtGetApiBase" "${onnx_base}" \
            "-I${onnx_base}/include -I${onnx_base}/include/onnxruntime/core/session" \
            "-L${onnx_base}/lib -lonnxruntime -lstdc++ -lpthread -lm -ldl" "${ONNXRUNTIME_VERSION#v}"; then
            # FFmpeg checks libonnxruntime with a BARE `require`/check_lib (NOT
            # require_pkg_config), so it ignores the synth .pc and compiles
            # `#include <onnxruntime_c_api.h>` with no -I. Export the resolved
            # paths so configure_ffmpeg can add them to --extra-cflags/-ldflags/
            # -libs; -lstdc++ is required because libonnxruntime.so is C++.
            _FFMPEG_ONNX_EXTRA_CFLAGS="-I${onnx_base}/include -I${onnx_base}/include/onnxruntime/core/session"
            _FFMPEG_ONNX_EXTRA_LDFLAGS="-L${onnx_base}/lib"
            _FFMPEG_ONNX_EXTRA_LIBS="-lstdc++"
            echo "ONNX Runtime enabled via synthesized pkg-config at ${onnx_base}."
            return 0
        fi
        # Known install present but synth-probe failed → do NOT fall through to the
        # vendor .pc (it would spuriously enable and hard-abort FFmpeg configure).
        echo "Skipping libonnxruntime: install present but synthesized pkg-config probe failed."
        return 1
    fi

    # No known install — try a vendor-provided working pkg-config module, if any.
    if ffmpeg_probe_pkg_config_feature "libonnxruntime" "libonnxruntime" \
        "onnxruntime_c_api.h" "OrtGetApiBase"; then
        return 0
    fi

    echo "Skipping libonnxruntime: no usable pkg-config module (ONNX Runtime absent or its headers do not compile)."
    return 1
}

# ---------------------------------------------------------------------------
# DNN backend probes — TensorFlow and OpenVINO
# ---------------------------------------------------------------------------

# Download TensorFlow C API SDK into a cache directory so it persists across
# rebuilds. FFmpeg's --enable-libtensorflow needs libtensorflow.so + headers.
ensure_tensorflow_c_sdk() {
    local cache_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}"
    local tf_dir="${cache_dir}/tensorflow-c"
    local tf_version="${TENSORFLOW_C_VERSION:-2.16.1}"
    local tf_archive tf_url

    if [ -f "${tf_dir}/lib/libtensorflow.so" ] && [ -f "${tf_dir}/include/tensorflow/c/c_api.h" ]; then
        echo "TensorFlow C SDK ${tf_version} already cached at ${tf_dir}"
        return 0
    fi

    mkdir -p "${cache_dir}" "${tf_dir}/lib" "${tf_dir}/include"

    case "$(uname -m)" in
        x86_64)
            tf_archive="libtensorflow-cpu-linux-x86_64-${tf_version}.tar.gz"
            ;;
        aarch64|arm64)
            tf_archive="libtensorflow-cpu-linux-aarch64-${tf_version}.tar.gz"
            ;;
        *)
            echo "Skipping TensorFlow C SDK: unsupported arch $(uname -m)"
            return 1
            ;;
    esac

    tf_url="https://github.com/tensorflow/tensorflow/archive/refs/tags/v${tf_version}.tar.gz"
    echo "Downloading TensorFlow C SDK ${tf_version}..."
    # Download just the C library from the TF release
    local tf_release_url="https://github.com/tensorflow/tensorflow/releases/download/v${tf_version}/${tf_archive}"
    if     download_file "${tf_release_url}" "${cache_dir}/${tf_archive}" 3 30 300 2>/dev/null \
        && [ -s "${cache_dir}/${tf_archive}" ]; then
        tar -xzf "${cache_dir}/${tf_archive}" -C "${cache_dir}" 2>/dev/null || true
        # The tarball extracts to ./lib/ and ./include/ relative to cache_dir
        if [ -d "${cache_dir}/lib" ] && [ -f "${cache_dir}/lib/libtensorflow.so" ]; then
            mv "${cache_dir}/lib" "${tf_dir}/lib" 2>/dev/null || true
            mv "${cache_dir}/include" "${tf_dir}/include" 2>/dev/null || true
        fi
        # Create a pkg-config file for FFmpeg's configure to find
        generate_pkgconfig_file "${cache_dir}/tensorflow.pc" \
            "TensorFlow" "TensorFlow C API" "${tf_version}" "${tf_dir}" \
            '-L${libdir} -ltensorflow'
        export PKG_CONFIG_PATH="${cache_dir}:${PKG_CONFIG_PATH:-}"
        echo "TensorFlow C SDK ${tf_version} installed to ${tf_dir}"
        return 0
    fi

    echo "TensorFlow C SDK download failed (trying alternate URL)..."
    # Fallback: use the full TF source release (much larger but always available)
    local alt_url="https://github.com/tensorflow/tensorflow/releases/download/v${tf_version}/libtensorflow-cpu-linux-x86_64-${tf_version}.tar.gz"
    if download_file "${alt_url}" "${cache_dir}/${tf_archive}" 3 30 600 2>/dev/null \
        && [ -s "${cache_dir}/${tf_archive}" ]; then
        tar -xzf "${cache_dir}/${tf_archive}" -C "${tf_dir}" 2>/dev/null || true
        echo "TensorFlow C SDK ${tf_version} installed (fallback URL)"
        return 0
    fi

    echo "WARNING: TensorFlow C SDK download failed. libtensorflow will not be available."
    return 1
}

ffmpeg_probe_libtensorflow() {
    # NOTE: LiteRT/TFLite (built in-stage) exposes a DIFFERENT API than the full
    # TensorFlow C API FFmpeg's libtensorflow backend requires
    # (tensorflow/c/c_api.h + TF_Version). Passing it off as libtensorflow made
    # FFmpeg's configure hard-fail, so we no longer do that — only the full TF C
    # SDK, resolved through a working pkg-config module, can back this backend.

    # Ensure the full TensorFlow C SDK is present (best-effort, cached download;
    # unavailable for arm64/riscv64, which then skip cleanly).
    local tf_cache="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/tensorflow-c"
    if [ ! -f "${tf_cache}/lib/libtensorflow.so" ]; then
        ensure_tensorflow_c_sdk || { echo "Skipping libtensorflow: full TensorFlow C SDK unavailable."; return 1; }
    fi

    export PKG_CONFIG_PATH="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}:${PKG_CONFIG_PATH:-}"
    if ffmpeg_probe_pkg_config_feature "libtensorflow" "tensorflow" \
        "tensorflow/c/c_api.h" "TF_Version TF_NewGraph"; then
        return 0
    fi

    # SDK present but no usable .pc — synthesize one and re-probe.
    local tf_base=""
    for d in "${tf_cache}" /usr/local/lib/tensorflow-c /opt/tensorflow-c; do
        [ -f "${d}/lib/libtensorflow.so" ] && { tf_base="${d}"; break; }
    done
    if [ -n "${tf_base}" ] && ffmpeg_enable_via_synth_pkgconfig "libtensorflow" "tensorflow" \
        "tensorflow/c/c_api.h" "TF_Version TF_NewGraph" "${tf_base}" \
        "-I${tf_base}/include" "-L${tf_base}/lib -ltensorflow" "${TENSORFLOW_C_VERSION:-2.16.1}"; then
        echo "TensorFlow C SDK enabled via synthesized pkg-config at ${tf_base}."
        return 0
    fi

    echo "Skipping libtensorflow: SDK not found or unusable."
    return 1
}

ffmpeg_probe_libopenvino() {
    local ov_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/openvino"
    local ov_pkg="${ov_dir}/runtime/lib/pkgconfig"

    # Vendored SDK with its own pkg-config dir — export it (not just inline) so
    # FFmpeg's configure child process resolves the same module our probe did.
    if [ -d "${ov_pkg}" ]; then
        export PKG_CONFIG_PATH="${ov_pkg}:${PKG_CONFIG_PATH:-}"
        if ffmpeg_probe_pkg_config_feature "libopenvino" "openvino" \
            "openvino/openvino.hpp openvino/c/openvino.h" "ov_get_openvino_version"; then
            return 0
        fi
    fi

    # If openvino is installed system-wide via apt, try pkg-config directly
    if ffmpeg_probe_pkg_config_feature "libopenvino" "openvino" \
        "openvino/openvino.hpp openvino/c/openvino.h" "ov_get_openvino_version"; then
        return 0
    fi

    # Direct install without a usable .pc — synthesize one and re-probe.
    local ov_base=""
    for d in "${ov_dir}" /opt/intel/openvino /usr/local/openvino; do
        if [ -f "${d}/runtime/lib/libopenvino.so" ] || [ -f "${d}/lib/libopenvino.so" ]; then
            ov_base="${d}"
            break
        fi
    done
    [ -z "${ov_base}" ] && { echo "Skipping libopenvino: SDK not found."; return 1; }

    local ov_lib_dir
    [ -d "${ov_base}/runtime/lib" ] && ov_lib_dir="${ov_base}/runtime/lib" || ov_lib_dir="${ov_base}/lib"
    if ffmpeg_enable_via_synth_pkgconfig "libopenvino" "openvino" \
        "openvino/c/openvino.h" "ov_get_openvino_version" "${ov_base}" \
        "-I${ov_base}/runtime/include" "-L${ov_lib_dir} -lopenvino" "${OPENVINO_VERSION:-2024.0}"; then
        return 0
    fi

    echo "Skipping libopenvino: SDK not found or unusable."
    return 1
}
