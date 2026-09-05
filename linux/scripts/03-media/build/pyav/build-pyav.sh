#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Build the PyAV (`import av`) wheel against the source-built FFmpeg (backlog
# ORPHAN-PINS). Best-effort like the other optional media payloads: every
# failure path leaves the wheel dir empty instead of aborting the media lane.
# Cross-wheel setuptools knobs: docs/linux-cross-builds.md § Cross Python wheels.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    echo ""
    echo "Build the PyAV (av) wheel against the source-built FFmpeg."
    echo ""
    echo "Environment:"
    echo "  PYAV_VERSION     PyAV release tag without the leading v (required)"
    echo "  FFMPEG_PREFIX    FFmpeg install prefix (default: /opt/ffmpeg)"
    echo "  PYAV_WHEELS_DIR  Wheel output dir (default: /opt/pyav/wheels)"
    echo "  USE_CCACHE       Compile through ccache when available (default: true)"
    exit 0
    ;;
esac

# PYAV_VERSION has two agreeing sources and deliberately no literal default here
# (C3): Dockerfile.media's ARG/ENV, and versions.env via media_common_init.
: "${FFMPEG_PREFIX:=/opt/ffmpeg}"
: "${PYAV_WHEELS_DIR:=/opt/pyav/wheels}"
: "${PYAV_SRC:=${TMPDIR:-/tmp}/pyav-$$}"

BUILD_PYTHON=""
FFMPEG_LIBDIR=""
NPROC="$(media_jobs)"

# Every non-fatal bail out goes through here: one greppable reason, empty wheel dir.
pyav_skip() {
    warn "PyAV wheel not built: $*"
    warn "The image ships without the FFmpeg->Python bridge; the app smoke's check_pyav optional-fails."
    exit 0
}

pyav_preflight() {
    if cross_build_is_active; then
        if ! cross_target_python_dev_ready; then
            pyav_skip "target Python $(cross_target_python_major_minor 2>/dev/null || echo '?') dev files are missing for $(cross_target_triplet 2>/dev/null || echo target)"
        fi
    fi

    # Explicit paths, never a glob-and-pick (backlog: nondeterministic file picks).
    local candidate
    for candidate in "${FFMPEG_PREFIX}/lib" "${FFMPEG_PREFIX}/lib64"; do
        if [ -f "${candidate}/libavcodec.so" ]; then
            FFMPEG_LIBDIR="${candidate}"
            break
        fi
    done
    [ -n "${FFMPEG_LIBDIR}" ] || pyav_skip "no libavcodec.so under ${FFMPEG_PREFIX}/lib or ${FFMPEG_PREFIX}/lib64"
    [ -f "${FFMPEG_PREFIX}/include/libavcodec/avcodec.h" ] \
        || pyav_skip "no ${FFMPEG_PREFIX}/include/libavcodec/avcodec.h"
    # --ffmpeg-dir pins the link to this prefix, never the cross pkg-config sysroot
    # (RV1-GST-PC); it hard-codes <dir>/lib, so lib64 rides on pyav_link_flags.
    info "FFmpeg for PyAV: headers=${FFMPEG_PREFIX}/include libs=${FFMPEG_LIBDIR}"

    BUILD_PYTHON="$(host_python_bin)" || pyav_skip "no host Python interpreter"
    [ -x "${BUILD_PYTHON}" ] || pyav_skip "host Python ${BUILD_PYTHON} is not executable"
    info "Build interpreter: ${BUILD_PYTHON} ($("${BUILD_PYTHON}" --version 2>&1))"
}

# The base stage already installs these; this only re-pins the range PyAV's
# pyproject requires (a base `--upgrade cython` could have moved past its `<4`).
pyav_install_build_requirements() {
    if command -v uv >/dev/null 2>&1; then
        UV_PYTHON="${BUILD_PYTHON}" uv pip install --quiet \
            "setuptools>=77" "cython>=3.1.0,<4" wheel \
            || warn "could not refresh PyAV build requirements; using whatever the base stage installed"
    fi
    "${BUILD_PYTHON}" -c 'import setuptools, Cython, wheel' >/dev/null 2>&1 \
        || pyav_skip "build interpreter lacks setuptools/Cython/wheel"
    info "PyAV build requirements: Cython $("${BUILD_PYTHON}" -c 'import Cython; print(Cython.__version__)' 2>/dev/null || echo '?'), setuptools $("${BUILD_PYTHON}" -c 'import setuptools; print(setuptools.__version__)' 2>/dev/null || echo '?')"
}

# Tag archive first, git clone as the mirror (NET1: no unmirrored download SPOF).
pyav_fetch() {
    local ref="v${PYAV_VERSION#v}"
    rm -rf "${PYAV_SRC}"
    mkdir -p "${PYAV_SRC}"
    info "Fetching PyAV ${ref}"
    download_and_extract "https://github.com/PyAV-Org/PyAV/archive/refs/tags/${ref}.tar.gz" "${PYAV_SRC}" 1 \
        || {
            warn "PyAV tarball download failed; falling back to git clone"
            rm -rf "${PYAV_SRC}"
            git clone --depth 1 --branch "${ref}" https://github.com/PyAV-Org/PyAV.git "${PYAV_SRC}" \
                || pyav_skip "could not fetch PyAV ${ref} (tarball and git clone both failed)"
        }
    [ -f "${PYAV_SRC}/setup.py" ] || pyav_skip "PyAV ${ref} checkout has no setup.py"
    info "PyAV source: ${PYAV_SRC} (version $(sed -n 's/^__version__ = "\(.*\)"/\1/p' "${PYAV_SRC}/av/about.py" 2>/dev/null || echo '?'))"
}

# ccache/sccache wraps the COMPILE command only; the link keeps the bare compiler.
pyav_compile_cc() {
    local cc="$1"
    local _launcher
    media_compiler_launcher _launcher
    if [ -n "${_launcher}" ]; then
        printf '%s' "${_launcher} ${cc}"
        return 0
    fi
    printf '%s' "${cc}"
}

# -rpath-link, not just -L: GNU ld does not consult -L for the transitive
# DT_NEEDED entries of libav*.so, so a cross link dies on "libx264.so.NNN ... not found".
pyav_link_flags() {
    local flags="-L${FFMPEG_LIBDIR} -Wl,-rpath,${FFMPEG_LIBDIR} -Wl,-rpath-link,${FFMPEG_LIBDIR}"
    local triplet="${CROSS_TARGET_TRIPLET:-}"
    if cross_build_is_active; then
        [ -n "${triplet}" ] || triplet="$(cross_target_triplet 2>/dev/null || true)"
        local dir
        for dir in "/usr/lib/${triplet}" "/lib/${triplet}"; do
            [ -n "${triplet}" ] && [ -d "${dir}" ] || continue
            flags="${flags} -L${dir} -Wl,-rpath-link,${dir}"
        done
        flags="${flags} --sysroot=/"
    fi
    printf '%s' "${flags}"
}

pyav_build_wheel() {
    local cc ldshared cflags ldflags ext_suffix="" plat_tag=""
    local -a plat_args=()

    # Must run first: it exports CC/CROSS_TARGET_TRIPLET, which the flag builders read.
    if cross_build_is_active; then
        setup_linux_cross_env
    fi

    cc="${CC:-gcc}"
    cflags="-O2"
    ldflags="$(pyav_link_flags)"

    if cross_build_is_active; then
        local py_mm py_inc py_arch_inc
        py_mm="$(cross_target_python_major_minor)" || pyav_skip "cannot resolve the target Python version"
        py_inc="$(cross_target_python_include_dir)" || pyav_skip "cannot resolve the target Python include dir"
        py_arch_inc="$(cross_target_python_arch_include_dir 2>/dev/null || printf '%s' "${py_inc}")"
        # -I first: the TARGET Python headers win over the host ones build_ext appends.
        cflags="-I${py_arch_inc} -I${py_inc} --sysroot=/ ${cflags}"
        ext_suffix=".cpython-${py_mm//./}-${CROSS_TARGET_TRIPLET}.so"
        plat_tag="$(cross_wheel_platform_tag)" || pyav_skip "cannot resolve the target wheel platform tag"
        plat_args=(--plat-name "${plat_tag}")
        info "PyAV cross: triplet=${CROSS_TARGET_TRIPLET} ext_suffix=${ext_suffix} plat=${plat_tag}"
    fi

    ldshared="${cc} -shared"
    cc="$(pyav_compile_cc "${cc}")"
    info "PyAV compile: CC=${cc} LDSHARED=${ldshared} jobs=${NPROC}"

    (
        cd "${PYAV_SRC}" || exit 1
        export CC="${cc}"
        export LDSHARED="${ldshared}"
        export CFLAGS="${cflags}"
        export LDFLAGS="${LDFLAGS:+${LDFLAGS} }${ldflags}"
        if [ -n "${ext_suffix}" ]; then
            export SETUPTOOLS_EXT_SUFFIX="${ext_suffix}"
            export _PYTHON_HOST_PLATFORM="${plat_tag}"
        fi
        "${BUILD_PYTHON}" setup.py "--ffmpeg-dir=${FFMPEG_PREFIX}" \
            build_ext -j "${NPROC}" \
            bdist_wheel "${plat_args[@]}" -d "${PYAV_WHEELS_DIR}"
    ) || pyav_skip "setup.py bdist_wheel failed (see the log above)"
}

# Report the RESULT (the extension actually inside the wheel), never just the intent.
pyav_report() {
    local wheel
    shopt -s nullglob
    local wheels=("${PYAV_WHEELS_DIR}"/av-*.whl)
    shopt -u nullglob
    [ "${#wheels[@]}" -gt 0 ] || pyav_skip "bdist_wheel produced no av-*.whl in ${PYAV_WHEELS_DIR}"
    for wheel in "${wheels[@]}"; do
        info "Built $(basename "${wheel}")"
        "${BUILD_PYTHON}" - "${wheel}" <<'PY' || true
import sys, zipfile
names = [n for n in zipfile.ZipFile(sys.argv[1]).namelist() if n.endswith(".so")]
print(f"  PyAV wheel carries {len(names)} extension(s); e.g. {names[0] if names else '<none>'}")
PY
    done
}

cleanup() {
    rm -rf "${PYAV_SRC}"
}

main() {
    # EXIT trap, not a tail call: pyav_skip exits from several depths.
    trap cleanup EXIT
    # Unconditional: Dockerfile.media's `COPY --from=pyav` needs the dir even on skip.
    mkdir -p "${PYAV_WHEELS_DIR}"
    info "build-pyav: version=${PYAV_VERSION} ffmpeg=${FFMPEG_PREFIX} out=${PYAV_WHEELS_DIR}"
    pyav_preflight
    pyav_install_build_requirements
    pyav_fetch
    pyav_build_wheel
    pyav_report
}

main "$@"
