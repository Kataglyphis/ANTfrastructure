#!/usr/bin/env bash
# opencv-ort.sh - OpenCV dnn/G-API get the chain ONNX Runtime and nothing else (owner rule 2026-09-23).
# Source-only (build-opencv.sh). NOT covered: which libonnxruntime the loader picks (configure-runtime.sh).

# The ORT the onnxruntime stage builds; build-opencv.sh fails without it.
OPENCV_ORT_CHAIN_ROOT=/usr/local/lib/onnxruntime-cpu

# opencv_ort_compat_tree <chain> <compat>: the chain in FindONNX's layout, minus the Windows-only
# DML headers (FindONNX would turn on gapi's dml_ep.cpp, which cannot compile here).
opencv_ort_compat_tree() {
    local chain="$1" compat="$2"
    if [ ! -d "${chain}/include" ] || [ ! -e "${chain}/lib/libonnxruntime.so" ]; then
        echo "ERROR: chain ONNX Runtime missing at ${chain} (needs include/ and lib/libonnxruntime.so)" >&2
        return 1
    fi
    rm -rf "${compat}"
    mkdir -p "${compat}"
    cp -aL "${chain}/include" "${compat}/include"
    rm -rf "${compat}/include/onnxruntime/core/providers/dml"
    ln -sfn "${chain}/lib" "${compat}/lib"
}

# opencv_ort_version <chain-lib-dir>: X.Y.Z, read off the chain's real libonnxruntime.so.X.Y.Z.
opencv_ort_version() {
    local lib
    lib="$(find "$1" -maxdepth 1 -type f -name 'libonnxruntime.so.[0-9]*.[0-9]*.[0-9]*' 2>/dev/null \
        | LC_ALL=C sort -V | tail -n 1 || true)"
    if [ -z "${lib}" ]; then
        echo "ERROR: no libonnxruntime.so.X.Y.Z under $1" >&2
        return 1
    fi
    printf '%s\n' "${lib##*/libonnxruntime.so.}"
}

# opencv_ort_cmake_args <out-array> <compat> <version>: every ORT input spelled out. HAVE_ONNXRUNTIME=1
# is what skips dnn's 1.25.1 download (opencv 5.0.0 modules/dnn/CMakeLists.txt:141); the gate proves it.
opencv_ort_cmake_args() {
    local -n _ooca_out="$1"
    _ooca_out+=(
        "-DWITH_ONNXRUNTIME=ON"
        "-DHAVE_ONNXRUNTIME=1"
        "-DDOWNLOAD_ONNXRUNTIME=OFF"
        "-DDOWNLOAD_ONNXRUNTIME_GPU=OFF"
        "-DONNXRUNTIME_PREFER_STATIC=OFF"
        "-DONNXRT_ROOT_DIR=$2"
        "-DONNXRUNTIME_VERSION=$3"
        "-DCMAKE_DISABLE_FIND_PACKAGE_onnxruntime=ON"
        "-DCMAKE_DISABLE_FIND_PACKAGE_ONNXRuntime=ON"
    )
}

# _opencv_ort_cache <CMakeCache.txt> <key>: the cached value of <key>, any type.
_opencv_ort_cache() {
    sed -n "s/^$2:[A-Z]*=//p" "$1" | head -n 1 || true
}

# _opencv_ort_log_findings <configure-log> <version>: dnn's download/extract/static lines,
# and the two lines that must be there.
_opencv_ort_log_findings() {
    local log="$1" ver="$2"
    grep -e 'DNN: Downloading ONNX Runtime' -e 'DNN: Extracting ONNX Runtime' \
        -e 'DNN: ONNX Runtime package' -e 'DNN: ONNX Runtime download' \
        -e 'attempting to download prebuilt' -e '3rdparty/onnxruntime' \
        -e 'ONNX Runtime static library selected' "${log}" | sed 's/^/configure log: /' || true
    grep -q -e 'DNN: ONNX Runtime enabled' "${log}" \
        || echo "configure log: no 'DNN: ONNX Runtime enabled' (dnn did not take ORT)"
    grep -F -e 'ONNX Runtime:' "${log}" | grep -qF -e "YES (ver ${ver})" \
        || echo "configure summary: no 'ONNX Runtime: YES (ver ${ver})'"
    return 0
}

# _opencv_ort_lib_finding <what> <value> <chain-lib-real>: the one ORT library CMake picked
# must be a live, shared file inside the chain.
_opencv_ort_lib_finding() {
    local what="$1" v="$2" chain_real="$3" lib
    lib="$(readlink -f -- "${v:-/nonexistent}" 2>/dev/null || true)"
    if [ -z "${chain_real}" ]; then
        echo "${what}='${v}': the chain lib dir does not resolve"
        return 0
    fi
    case "${lib}" in
        *.a) echo "${what}='${v}' is a static ORT (a second ORT inside OpenCV)" ;;
        "${chain_real}"/*) [ -e "${lib}" ] || echo "${what}='${v}' does not exist" ;;
        *) echo "${what}='${v}' resolves to '${lib}', not into ${chain_real}" ;;
    esac
}

# _opencv_ort_cache_findings <cache> <compat> <chain> <version>: what CMake actually cached.
_opencv_ort_cache_findings() {
    local cache="$1" compat="$2" chain="$3" ver="$4" v key
    grep -F -e '3rdparty/onnxruntime' "${cache}" | sed 's/^/CMakeCache: /' || true
    v="$(_opencv_ort_cache "${cache}" ONNXRT_ROOT_DIR)"
    [ "${v}" = "${compat}" ] || echo "CMakeCache: ONNXRT_ROOT_DIR='${v}', not ${compat}"
    v="$(_opencv_ort_cache "${cache}" ONNX_VERSION)"
    [ "${v}" = "${ver}" ] || echo "CMakeCache: ONNX_VERSION='${v}', not the chain's ${ver}"
    v="$(_opencv_ort_cache "${cache}" ONNX_INCLUDE_DIR)"
    case "${v}" in "${compat}/include"*) ;; *) echo "CMakeCache: ONNX_INCLUDE_DIR='${v}' is outside ${compat}/include" ;; esac
    _opencv_ort_lib_finding "CMakeCache: ONNX_LIBRARIES" "$(_opencv_ort_cache "${cache}" ONNX_LIBRARIES)" \
        "$(readlink -f -- "${chain}/lib" 2>/dev/null || true)"
    for key in onnxruntime_DIR ONNXRuntime_DIR; do
        v="$(_opencv_ort_cache "${cache}" "${key}")"
        case "${v}" in ""|*-NOTFOUND) ;; *) echo "CMakeCache: ${key}='${v}' (a CMake ORT package was found)" ;; esac
    done
}

# opencv_ort_configure_findings <log> <CMakeCache.txt> <compat> <chain> <version>: one line per sign
# that configure saw an ORT other than the chain; no output = chain only. NOT covered: the install tree.
opencv_ort_configure_findings() {
    [ -f "$1" ] || { echo "configure log missing: $1"; return 0; }
    [ -f "$2" ] || { echo "CMakeCache.txt missing: $2"; return 0; }
    _opencv_ort_log_findings "$1" "$5"
    _opencv_ort_cache_findings "$2" "$3" "$4" "$5"
}

# opencv_ort_assert_configure <build-dir> <compat> <version>: the configure gate; 1 on any finding.
opencv_ort_assert_configure() {
    local findings
    findings="$(opencv_ort_configure_findings "$1/opencv-configure.log" "$1/CMakeCache.txt" \
        "$2" "${OPENCV_ORT_CHAIN_ROOT}" "$3")"
    if [ -n "${findings}" ]; then
        printf 'ERROR: OpenCV configure saw an ONNX Runtime other than the chain:\n%s\n' "${findings}" >&2
        return 1
    fi
    echo "OpenCV ORT gate: dnn/G-API configured against the chain ONNX Runtime $3 only"
}

# _opencv_ort_installed <prefix>: every libonnxruntime* file or link under <prefix>, listed up front.
_opencv_ort_installed() {
    find "$1" \( -type f -o -type l \) -name 'libonnxruntime*' 2>/dev/null | LC_ALL=C sort || true
}

# opencv_ort_forward_installed <prefix> <chain-lib-dir>: dnn's install rule copies libonnxruntime.so*
# into <prefix>; swap each for a link to the chain file, refusing bytes the chain does not have.
opencv_ort_forward_installed() {
    local prefix="$1" chain_lib="$2" f name
    local -a found=()
    mapfile -t found < <(_opencv_ort_installed "${prefix}")
    for f in "${found[@]}"; do
        name="${f##*/}"
        if [ ! -e "${chain_lib}/${name}" ]; then
            echo "ERROR: ${f} has no chain counterpart ${chain_lib}/${name}" >&2
            return 1
        fi
        if [ ! -L "${f}" ] && ! cmp -s "${f}" "${chain_lib}/${name}"; then
            echo "ERROR: ${f} differs from the chain's ${chain_lib}/${name}: OpenCV installed a foreign ORT" >&2
            return 1
        fi
        ln -sfn "${chain_lib}/${name}" "${f}"
    done
}

# opencv_ort_install_findings <prefix> <chain-lib-dir>: every libonnxruntime* under <prefix> must be a
# live link into the chain; no output = no second ORT file. NOT covered: files outside <prefix>.
opencv_ort_install_findings() {
    local f chain_real
    local -a found=()
    chain_real="$(readlink -f -- "$2" 2>/dev/null || true)"
    mapfile -t found < <(_opencv_ort_installed "$1")
    for f in "${found[@]}"; do
        if [ -L "${f}" ]; then
            _opencv_ort_lib_finding "installed" "${f}" "${chain_real}"
        else
            echo "COPY ${f} (a second ORT file; only links into the chain are allowed)"
        fi
    done
}

# opencv_ort_assert_installed <prefix>: the install gate -- forward dnn's copies, then prove none is left.
opencv_ort_assert_installed() {
    local findings
    opencv_ort_forward_installed "$1" "${OPENCV_ORT_CHAIN_ROOT}/lib" || return 1
    findings="$(opencv_ort_install_findings "$1" "${OPENCV_ORT_CHAIN_ROOT}/lib")"
    if [ -n "${findings}" ]; then
        printf 'ERROR: a second ONNX Runtime under %s:\n%s\n' "$1" "${findings}" >&2
        return 1
    fi
    echo "OpenCV ORT gate: $1 holds no ORT file of its own, only links into the chain"
}
