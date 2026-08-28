#!/usr/bin/env bash
# ffmpeg-dnn-backends.sh - FFmpeg DNN backend probes (ONNX Runtime, TensorFlow, OpenVINO)
# Source-only helper; sourced by build-ffmpeg.sh — expects its set -euo pipefail and IFS.

ffmpeg_probe_libonnxruntime() {
    # The vendor libonnxruntime.pc resolves via --exists but its -I does not find the
    # header, and a spurious pass here HARD-ABORTS FFmpeg's own require. When the known
    # install is present, go STRAIGHT to the synthesized .pc — never the vendor one.
    local onnx_base="/usr/local/lib/onnxruntime-cpu"
    # ONNXRUNTIME_VERSION may be unset (set -u); the callee defaults an empty version.
    local onnx_ver="${ONNXRUNTIME_VERSION:-}"
    onnx_ver="${onnx_ver#v}"
    if [ -f "${onnx_base}/lib/libonnxruntime.so" ] && [ -f "${onnx_base}/include/onnxruntime_c_api.h" ]; then
        if ffmpeg_enable_via_synth_pkgconfig "libonnxruntime" "libonnxruntime" \
            "onnxruntime_c_api.h" "OrtGetApiBase" "${onnx_base}" \
            "-I${onnx_base}/include -I${onnx_base}/include/onnxruntime/core/session" \
            "-L${onnx_base}/lib -lonnxruntime -lstdc++ -lpthread -lm -ldl" "${onnx_ver}"; then
            # FFmpeg checks libonnxruntime with a BARE `require`, which never sees the
            # .pc's -I; export the paths for --extra-cflags/-ldflags/-libs instead.
            # -lstdc++ is required because libonnxruntime.so is C++.
            _FFMPEG_ONNX_EXTRA_CFLAGS="-I${onnx_base}/include -I${onnx_base}/include/onnxruntime/core/session"
            _FFMPEG_ONNX_EXTRA_LDFLAGS="-L${onnx_base}/lib"
            _FFMPEG_ONNX_EXTRA_LIBS="-lstdc++"
            echo "ONNX Runtime enabled via synthesized pkg-config at ${onnx_base}."
            return 0
        fi
        # Do NOT fall through to the vendor .pc: it would spuriously enable the
        # backend and hard-abort FFmpeg configure.
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

# Cache the TensorFlow C API SDK (libtensorflow.so + headers) across rebuilds.
ensure_tensorflow_c_sdk() {
    # Belt-and-suspenders gate for the ~500 MB download; the primary one is the call
    # site in _ffmpeg_probe_dnn_backends. See docs/linux-cross-builds.md FFMPEG_ENABLE_TF.
    if command -v is_truthy >/dev/null 2>&1 && ! is_truthy "${FFMPEG_ENABLE_TF:-0}"; then
        echo "Skipping TensorFlow C SDK: FFMPEG_ENABLE_TF is off (optional DNN backend, ~500 MB). Set FFMPEG_ENABLE_TF=1 to enable."
        return 1
    fi
    local cache_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}"
    local tf_dir="${cache_dir}/tensorflow-c"
    local tf_version="${TENSORFLOW_C_VERSION:-2.18.0}"
    local tf_archive

    if [ -f "${tf_dir}/lib/libtensorflow.so" ] && [ -f "${tf_dir}/include/tensorflow/c/c_api.h" ]; then
        echo "TensorFlow C SDK ${tf_version} already cached at ${tf_dir}"
        return 0
    fi

    # Do NOT pre-create ${tf_dir}/lib and ${tf_dir}/include: the mv below would nest
    # them one level deeper, so the cached-SDK check never passes again.
    mkdir -p "${cache_dir}" "${tf_dir}"

    case "$(uname -m)" in
        x86_64)
            tf_archive="libtensorflow-cpu-linux-x86_64.tar.gz"
            ;;
        aarch64|arm64)
            echo "Skipping TensorFlow C SDK: upstream publishes no aarch64 C-library build (last x86_64 build is 2.18.0)"
            return 1
            ;;
        *)
            echo "Skipping TensorFlow C SDK: unsupported arch $(uname -m)"
            return 1
            ;;
    esac

    echo "Downloading TensorFlow C SDK ${tf_version}..."
    # GCS, not GitHub releases: upstream stopped attaching C-library assets after
    # 2.18.0, so every version since 2.19 404s there.
    local tf_release_url="https://storage.googleapis.com/tensorflow/versions/${tf_version}/${tf_archive}"
    local _tf_fetch_ok=0
    if [ -n "${TENSORFLOW_C_SHA256:-}" ]; then
        download_verified_file "${tf_release_url}" "${TENSORFLOW_C_SHA256}" "${cache_dir}/${tf_archive}" && _tf_fetch_ok=1
    else
        echo "WARNING: TENSORFLOW_C_SHA256 unset — fetching libtensorflow UNVERIFIED (add the pin to versions.env)" >&2
        download_file "${tf_release_url}" "${cache_dir}/${tf_archive}" 3 30 300 && _tf_fetch_ok=1
    fi
    if [ "${_tf_fetch_ok}" = "1" ] \
        && [ -s "${cache_dir}/${tf_archive}" ]; then
        # Extraction failure must disable the backend, not mask as success (a live .pc
        # over an empty ${tf_dir}); drop the corrupt archive so the next build refetches.
        if ! tar -xzf "${cache_dir}/${tf_archive}" -C "${cache_dir}"; then
            rm -f "${cache_dir}/${tf_archive}"
            echo "WARNING: TensorFlow C SDK archive extraction failed (corrupt/truncated ${tf_archive}). libtensorflow will not be available."
            return 1
        fi
        # The .pc below advertises ${tf_dir} to FFmpeg's configure, so it may only be
        # generated once the extracted ./lib + ./include layout demonstrably exists.
        if [ ! -f "${cache_dir}/lib/libtensorflow.so" ] \
            || [ ! -f "${cache_dir}/include/tensorflow/c/c_api.h" ]; then
            echo "WARNING: TensorFlow C SDK archive lacks the expected lib/ + include/ layout. libtensorflow will not be available."
            return 1
        fi
        if ! mv "${cache_dir}/lib" "${tf_dir}/lib" \
            || ! mv "${cache_dir}/include" "${tf_dir}/include"; then
            echo "WARNING: failed to move TensorFlow C SDK into ${tf_dir}. libtensorflow will not be available."
            return 1
        fi
        generate_pkgconfig_file "${cache_dir}/tensorflow.pc" \
            "TensorFlow" "TensorFlow C API" "${tf_version}" "${tf_dir}" \
            '-L${libdir} -ltensorflow'
        export PKG_CONFIG_PATH="${cache_dir}:${PKG_CONFIG_PATH:-}"
        echo "TensorFlow C SDK ${tf_version} installed to ${tf_dir}"
        return 0
    fi

    echo "WARNING: TensorFlow C SDK download failed. libtensorflow will not be available."
    return 1
}

ffmpeg_probe_libtensorflow() {
    # LiteRT/TFLite exposes a DIFFERENT API than the tensorflow/c/c_api.h this backend
    # requires; only the full TF C SDK can back it (passing LiteRT off as it hard-fails
    # FFmpeg's configure).
    local tf_cache="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/tensorflow-c"
    if [ ! -f "${tf_cache}/lib/libtensorflow.so" ]; then
        ensure_tensorflow_c_sdk || { echo "Skipping libtensorflow: full TensorFlow C SDK unavailable."; return 1; }
    fi

    export PKG_CONFIG_PATH="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}:${PKG_CONFIG_PATH:-}"
    if ffmpeg_probe_pkg_config_feature "libtensorflow" "tensorflow" \
        "tensorflow/c/c_api.h" "TF_Version TF_NewGraph"; then
        # FFmpeg's libtensorflow check is a BARE require, which never sees the .pc's -I;
        # export the resolved paths as --extra-cflags/-ldflags/-libs, which it does honor.
        _FFMPEG_TF_EXTRA_CFLAGS="-I${tf_cache}/include"
        _FFMPEG_TF_EXTRA_LDFLAGS="-L${tf_cache}/lib"
        # -ltensorflow must stay OUT of the global --extra-libs: FFmpeg validates those by
        # compiling AND EXECUTING a trivial main(), which then dies loading
        # libtensorflow.so.2. Only FFmpeg's own require line (link-only) may add it.
        _FFMPEG_TF_EXTRA_LIBS="-lstdc++"
        # Make libtensorflow.so.2 loadable for executed checks and the smoke;
        # bundle_sdk_runtime_libs then copies it into the image.
        export LD_LIBRARY_PATH="${tf_cache}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        return 0
    fi

    # SDK present but no usable .pc — synthesize one and re-probe.
    local tf_base=""
    for d in "${tf_cache}" /usr/local/lib/tensorflow-c /opt/tensorflow-c; do
        [ -f "${d}/lib/libtensorflow.so" ] && { tf_base="${d}"; break; }
    done
    if [ -n "${tf_base}" ] && ffmpeg_enable_via_synth_pkgconfig "libtensorflow" "tensorflow" \
        "tensorflow/c/c_api.h" "TF_Version TF_NewGraph" "${tf_base}" \
        "-I${tf_base}/include" "-L${tf_base}/lib -ltensorflow" "${TENSORFLOW_C_VERSION:-2.18.0}"; then
        # Same bare-require caveat as above: the synth .pc alone is not enough.
        _FFMPEG_TF_EXTRA_CFLAGS="-I${tf_base}/include"
        _FFMPEG_TF_EXTRA_LDFLAGS="-L${tf_base}/lib"
        # Same rule: -ltensorflow stays out of the global --extra-libs.
        _FFMPEG_TF_EXTRA_LIBS="-lstdc++"
        export LD_LIBRARY_PATH="${tf_base}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        echo "TensorFlow C SDK enabled via synthesized pkg-config at ${tf_base}."
        return 0
    fi

    echo "Skipping libtensorflow: SDK not found or unusable."
    return 1
}

ffmpeg_probe_libopenvino() {
    local ov_dir="${FFMPEG_SDK_CACHE:-/var/cache/ffmpeg-sdks}/openvino"
    local ov_pkg="${ov_dir}/runtime/lib/pkgconfig"

    # Export (not just inline) so FFmpeg's configure child resolves the same module.
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
        "-I${ov_base}/runtime/include" "-L${ov_lib_dir} -lopenvino" "${OPENVINO_VERSION:-2026.2.1}"; then
        return 0
    fi

    echo "Skipping libopenvino: SDK not found or unusable."
    return 1
}
