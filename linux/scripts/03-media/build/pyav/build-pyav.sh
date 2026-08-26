#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# build-pyav.sh - build the PyAV (`import av`) wheel against the built FFmpeg
# ==============================================================================
# ORPHAN-PINS (backlog A1): versions.env pinned PYAV_VERSION while NOTHING under
# linux/ ever built it, so every runtime smoke reported `No module named 'av'`
# and a fully shipped FFmpeg stack had no Python bridge. This builds the wheel
# in the media lane, in a stage layered directly on the FFmpeg it links against.
#
# PyAV is a plain setuptools + Cython project (pyproject: setuptools>=77,
# cython>=3.1,<4; no runtime deps) whose only native dependency is FFmpeg.
# setup.py takes it either from pkg-config or from `--ffmpeg-dir=<prefix>`,
# which yields include_dirs=<prefix>/include, library_dirs=<prefix>/lib and the
# seven lib names (avformat avcodec avdevice avutil avfilter swscale
# swresample). We pass --ffmpeg-dir so the link is pinned to ${FFMPEG_PREFIX}
# and is never resolved through the cross pkg-config sysroot rules (RV1-GST-PC:
# one ports .pc with an empty prefix poisons every consumer downstream).
#
# Cross-compilation contract - every knob below is read by setuptools itself
# (setuptools/_distutils/compilers/C/unix.py configure_system, and
# setuptools/command/build_ext.py get_ext_filename):
#   CC        - replaces the interpreter's compiler; may be multi-word
#               ("ccache <cross-gcc>"), set_executables shlex-splits it.
#   LDSHARED  - explicit "<cross-gcc> -shared"; without it the link command is
#               derived from the HOST interpreter's sysconfig.
#   CFLAGS    - REPLACES (not appends to) the sysconfig CFLAGS and lands in the
#               command line BEFORE the extension's own -I dirs, which is what
#               makes the TARGET Python headers win over the host ones that
#               build_ext always appends. Carries -O2 because the sysconfig
#               optimisation flags are replaced with it.
#   SETUPTOOLS_EXT_SUFFIX - the target SOABI suffix. Without it the extensions
#               are named .cpython-<mm>-x86_64-linux-gnu.so, which the target
#               interpreter never even considers at import time
#               (importlib EXTENSION_SUFFIXES) - the wheel installs and
#               `import av` dies. runtime/verify-wheels.sh asserts this suffix.
#   _PYTHON_HOST_PLATFORM - makes get_platform() (and hence the wheel platform
#               tag) the target one, so the wheel is born correctly tagged and
#               runtime/repair-wheels.sh's blanket retag is only a safety net.
#
# Output: ${PYAV_WHEELS_DIR} (default /opt/pyav/wheels), which Dockerfile.media
# COPYs into /opt/wheels of the media final stage - the canonical wheelhouse
# that repair-wheels.sh strips/retags, verify-wheels.sh checks and
# assemble-torch-app.sh's reconcile_local_wheels installs into the app venv.
#
# BEST-EFFORT by contract: the wheel dir is created first and every failure
# path leaves it empty instead of aborting the media lane, exactly like the
# other optional media payloads (TVM wheels, rice-proto, IREE). An empty dir
# reproduces today's behaviour: the app smoke's check_pyav optional-fails.
# ==============================================================================

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

# PYAV_VERSION has TWO agreeing sources and no literal default here (C3 - a
# third literal is exactly how a pin silently drifts): Dockerfile.media declares
# the ARG with the sync_versions-maintained default and promotes it to ENV, and
# 01-core/common.sh (loaded by media_common_init above) additionally loads
# versions.env from the mounted 01-core, with the environment winning. There is
# deliberately no emptiness guard: with common.sh loaded the value cannot be
# empty, and a guard that cannot fire is worse than none (it reads as a check).
: "${FFMPEG_PREFIX:=/opt/ffmpeg}"
: "${PYAV_WHEELS_DIR:=/opt/pyav/wheels}"
: "${PYAV_SRC:=${TMPDIR:-/tmp}/pyav-$$}"

BUILD_PYTHON=""
FFMPEG_LIBDIR=""
NPROC="$(media_jobs)"

# ------------------------------------------------------------------------------
# Skip helper - every non-fatal bail out goes through here so the reason is one
# greppable line and the (already created) wheel dir stays empty.
# ------------------------------------------------------------------------------
pyav_skip() {
    warn "PyAV wheel not built: $*"
    warn "The image ships without the FFmpeg->Python bridge; the app smoke's check_pyav optional-fails."
    exit 0
}

# ------------------------------------------------------------------------------
# Preflight - target Python headers (cross only), FFmpeg headers/libs, and a
# build interpreter that can run setuptools + Cython.
# ------------------------------------------------------------------------------
pyav_preflight() {
    if cross_build_is_active; then
        if ! cross_target_python_dev_ready; then
            pyav_skip "target Python $(cross_target_python_major_minor 2>/dev/null || echo '?') dev files are missing for $(cross_target_triplet 2>/dev/null || echo target)"
        fi
    fi

    # Explicit known paths, never a glob-and-pick (see the backlog's
    # nondeterministic-file-picks verdict); the RESULT is echoed below.
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
    # setup.py --ffmpeg-dir hard-codes <dir>/lib; a lib64 layout is passed
    # through the explicit -L/-rpath flags instead (see pyav_link_flags).
    info "FFmpeg for PyAV: headers=${FFMPEG_PREFIX}/include libs=${FFMPEG_LIBDIR}"

    BUILD_PYTHON="$(host_python_bin)" || pyav_skip "no host Python interpreter"
    [ -x "${BUILD_PYTHON}" ] || pyav_skip "host Python ${BUILD_PYTHON} is not executable"
    info "Build interpreter: ${BUILD_PYTHON} ($("${BUILD_PYTHON}" --version 2>&1))"
}

# ------------------------------------------------------------------------------
# Build requirements. PyAV's pyproject is the single source of truth for the
# ranges; the media base stage already installs setuptools/wheel/cython, so this
# only has to guarantee the RANGE (a base `--upgrade cython` could have moved
# past PyAV's `<4`). Best-effort install, hard gate on importability.
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Fetch - immutable GitHub tag archive, git clone as the fallback (NET1: never
# leave a single download host as an unmirrored SPOF).
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Compiler command for the extension compiles. ccache is used exactly like
# build-ffmpeg.sh does it (`ccache ${CC}` on cross, `ccache gcc` otherwise);
# the LINK command deliberately keeps the bare compiler.
# ------------------------------------------------------------------------------
pyav_compile_cc() {
    local cc="$1"
    if command -v ccache >/dev/null 2>&1 && is_truthy "${USE_CCACHE:-true}"; then
        printf '%s' "ccache ${cc}"
        return 0
    fi
    printf '%s' "${cc}"
}

# ------------------------------------------------------------------------------
# Link flags. -rpath pins the runtime lookup to the shipped FFmpeg (the image
# ENV also carries it on LD_LIBRARY_PATH); -rpath-link lets ld resolve the
# TRANSITIVE DT_NEEDED entries of libav*.so (x264, opus, ...) - GNU ld does NOT
# consult -L for those, which is exactly how a cross link ends in
# "libx264.so.NNN, needed by libavcodec.so, not found".
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Run setup.py bdist_wheel with the cross env applied (same idiom as the
# torch/torchvision cross wheels in 05-frameworks/torch/build-app-wheelhouse.sh).
# ------------------------------------------------------------------------------
pyav_build_wheel() {
    local cc ldshared cflags ldflags ext_suffix="" plat_tag=""
    local -a plat_args=()

    # FIRST: setup_linux_cross_env is what exports CC/CROSS_TARGET_TRIPLET, both
    # of which the flag builders below read.
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
        # -I first => the TARGET pyconfig.h/Python.h win over the host ones
        # build_ext appends from the running interpreter's sysconfig.
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

# ------------------------------------------------------------------------------
# Report the RESULT (wheel name + the extension SOABI actually inside it), never
# just the intent. verify-wheels.sh re-asserts the SOABI in the final stage.
# ------------------------------------------------------------------------------
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
    # EXIT trap, not a tail call: pyav_skip exits from several depths and the
    # source tree must go in every one of them.
    trap cleanup EXIT
    # First, unconditionally: Dockerfile.media's `COPY --from=pyav` needs the
    # directory to exist even when the build is skipped.
    mkdir -p "${PYAV_WHEELS_DIR}"
    info "build-pyav: version=${PYAV_VERSION} ffmpeg=${FFMPEG_PREFIX} out=${PYAV_WHEELS_DIR}"
    pyav_preflight
    pyav_install_build_requirements
    pyav_fetch
    pyav_build_wheel
    pyav_report
}

main "$@"
