#!/usr/bin/env bash
set -euo pipefail

# setup-torch-venv.sh
# Consolidated torch venv creation and application assembly for Dockerfile.torch.
# Replaces the three separate RUN blocks that duplicate the cross-mode skip guard.

TORCH_APP_MODE="${TORCH_APP_MODE:-all}"
VENV="${VENV:-/opt/venv}"
BUILD_MODE="${BUILD_MODE:-native}"

# The target-native GCC/G++ swapped in by swap-native-gcc.sh is a relocated
# Canadian-cross build whose baked-in sysroot does not include the runtime
# image's /usr/include. When PyPI ships no wheel for the target arch (e.g. on
# riscv64), pip compiles from source under QEMU and the build fails to find libc
# headers:
#   C:   "fatal error: string.h: No such file or directory"
#   C++: <cstdlib> does `#include_next <stdlib.h>` -> "stdlib.h: No such file"
# CPATH (=-I, searched BEFORE system dirs) fixes plain C includes but NOT the
# C++ #include_next, which must resolve /usr/include AFTER the libstdc++ headers.
# So also inject the system dirs with -idirafter (appended AFTER all built-in
# dirs) via *FLAGS. This is the same logic as the canonical helper
# append_cross_idirafter() in 01-core/common.sh, inlined here deliberately: the
# torch stage does not COPY common.sh (nor its load-versions-env.sh chain), and
# pulling that in just for six flag lines is not worth the extra surface. Keep
# the two in sync -- verify-critical-fixes.sh fix6 guards this. Exported so
# pip/setuptools child compiles (C and C++) inherit them; no-op when a prebuilt
# wheel is used (no compilation).
_mi="$(compgen -G '/usr/include/*-linux-gnu' 2>/dev/null | head -1 || true)"
_ml="$(compgen -G '/usr/lib/*-linux-gnu' 2>/dev/null | head -1 || true)"
_idaf="-idirafter /usr/include"
[ -n "${_mi}" ] && _idaf="-idirafter ${_mi} ${_idaf}"
export CPATH="${CPATH:+${CPATH}:}${_mi:+${_mi}:}/usr/include"
export CPPFLAGS="${CPPFLAGS:+${CPPFLAGS} }${_idaf}"
export CFLAGS="${CFLAGS:+${CFLAGS} }${_idaf}"
export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }${_idaf}"
export LIBRARY_PATH="${LIBRARY_PATH:+${LIBRARY_PATH}:}${_ml:+${_ml}:}/usr/lib"

cross_skip() {
  if [ "${BUILD_MODE}" = "cross" ]; then
    echo "Skipping ${1:-torch step} in pure cross artifact mode"
    return 0
  fi
  return 1
}

# Resolve the venv's python3.X/site-packages dir once, glob-safe. `test -d` does
# NOT glob, so `[ -d "${VENV}/lib/python3."*/site-packages ]` misfires when the
# venv contains more than one python3.X dir (or zero). Callers use the returned
# path both as a -d test subject and as a cp destination. Empty output = none.
venv_site_packages() {
  compgen -G "${VENV}/lib/python3.*/site-packages" 2>/dev/null | head -1
}

setup_torch_venv() {
  cross_skip "torch venv creation" && return 0

  if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
  fi

  local python_bin
  python_bin="$(command -v python3.14 || command -v python3 || true)"
  if [ -z "${python_bin}" ]; then
    python_bin="$(find /usr/local/bin -name 'python3.*' -type f 2>/dev/null | head -1 || true)"
  fi

  test -x "${python_bin}" || {
    echo "Python interpreter not found in the base image" >&2
    ls -1 /usr/local/bin/python* 2>/dev/null || true
    exit 1
  }

  local venv_args=(--seed --python="${python_bin}")
  # On foreign architectures running under QEMU, the source-built GCC may
  # fail to fork its cc1/as sub-processes, breaking pip sdist builds (e.g.
  # pycairo via meson).  Use --system-site-packages so pip sees apt-installed
  # python3-cairo and skips the source build.
  if [ "$(uname -m)" != "x86_64" ]; then
    venv_args+=(--system-site-packages)
  fi
  uv venv "${venv_args[@]}" "${VENV}"
}

seed_opencv5_bindings() {
  # If OpenCV 5.x Python bindings were built during the media stage, they
  # live at /opt/opencv5/lib/python3.*/site-packages/cv2.  Create a .pth
  # file in the venv so `import cv2` resolves to the source-built version
  # instead of downloading an older PyPI wheel.
  local cv2_dir
  cv2_dir="$(find /opt/opencv5/lib/python3.*/site-packages -maxdepth 1 -name cv2 -type d 2>/dev/null | head -1 || true)"
  if [ -n "${cv2_dir}" ]; then
    local site_pkg_dir
    site_pkg_dir="$(venv_site_packages)"
    local pth="${site_pkg_dir}/opencv5.pth"
    local parent
    parent="$(dirname "${cv2_dir}")"
    if [ -d "${site_pkg_dir}" ]; then
      echo "${parent}" > "${pth}" 2>/dev/null || true
    fi
    echo "Added OpenCV5 bindings .pth: ${parent}"

    # Cross-compiled cv2.so gets the host platform suffix (x86_64) from
    # cmake's FindPython3.  Rename it to match the runtime target platform
    # suffix so the extension is loadable on the real architecture.
    local host_arch target_suffix so_dir
    host_arch="$(uname -m)"
    target_suffix="$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))' 2>/dev/null || true)"
    if [ "${host_arch}" != "x86_64" ] && [ -n "${target_suffix}" ]; then
      so_dir="$(find "${cv2_dir}" -name 'python-3.*' -type d 2>/dev/null | head -1 || true)"
      if [ -n "${so_dir}" ]; then
        local old_so
        old_so="$(find "${so_dir}" -name 'cv2.cpython-3*.so' -type f 2>/dev/null | head -1 || true)"
        if [ -n "${old_so}" ] && [ ! "${old_so}" = "${so_dir}/cv2${target_suffix}" ]; then
          mv "${old_so}" "${so_dir}/cv2${target_suffix}" 2>/dev/null || true
          echo "Renamed cv2 .so to target suffix: ${target_suffix}"
        fi
      fi
    fi
  fi
}

# cv2.abi3.so's dynamic deps. The locally-built OpenCV python wheel
# (opencv-contrib-python) in /opt/wheels is a plain linux_x86_64 wheel (not
# manylinux): it bundles nothing and dynamically links the full system stack plus
# the source-built ffmpeg in /opt/ffmpeg. The ffmpeg libs in turn pull external
# codec runtime libraries that are NOT part of the GTK/GLib stack and are not
# otherwise installed in the runtime image. The list below (libtbb12 ..
# libgraphene-1.0-0) provides exactly the sonames that `ldd` reports as unresolved
# for cv2.abi3.so once /opt payload dirs are on the loader path. Removing any of
# them breaks `import cv2` in the torch venv.
_install_cv2_runtime_apt() {
  apt-get install -y --no-install-recommends \
    libgirepository-2.0-dev libcairo2-dev libgirepository1.0-dev \
    python3-gi python3-cairo python3-cairo-dev python3-gi-cairo \
    gir1.2-glib-2.0 gir1.2-gtk-3.0 \
    git libopenblas-dev liblapack-dev \
    libgtk-3-dev \
    libglib2.0-dev \
    libjpeg-dev \
    libtiff-dev \
    libpng-dev \
    libsdl2-dev \
    libnotify-dev \
    libsm-dev \
    libxtst-dev \
    freeglut3-dev \
    libxxf86vm-dev \
    libegl1-mesa-dev \
    libglu1-mesa-dev \
    pkg-config \
    libfreetype6-dev \
    libqhull-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libtbb12 \
    libunwind8 \
    libdc1394-25 \
    libva2 libva-drm2 libva-x11-2 libvdpau1 \
    libaom3 libdav1d7 libsvtav1enc2 libx265-215 libvpx12 \
    libmp3lame0 libopus0 libvorbis0a libvorbisenc2 \
    libopencore-amrnb0 libopencore-amrwb0 \
    libass9 libsndio7.0 libopenexr-3-1-30 libgraphene-1.0-0 \
    libavformat62 libavcodec62 libswscale9 libswresample6 libavdevice62 libavfilter11
}

# FFmpeg external-codec RUNTIME libraries: install EXACTLY the apt packages the
# media stage recorded as /opt/ffmpeg's real link-time deps (see
# emit_runtime_apt_manifest in build-ffmpeg.sh). This auto-tracks whatever
# codecs were probe-enabled per arch -- no soname guessing against the Ubuntu
# base. Best-effort per package so a name unavailable for this arch can't fail
# the build; the ffmpeg smoke (now pipefail-correct) is the backstop that flags
# a genuinely missing soname. The hardcoded opencore-amr entries above remain as
# a baseline for when the manifest is absent (older media images).
_install_ffmpeg_runtime_codecs() {
  if [ -s /opt/ffmpeg/runtime-apt-packages.txt ]; then
    local _ff_pkgs
    _ff_pkgs="$(tr '\n' ' ' < /opt/ffmpeg/runtime-apt-packages.txt)"
    if [ -n "${_ff_pkgs// /}" ]; then
      # shellcheck disable=SC2086
      if apt-get install -y --no-install-recommends ${_ff_pkgs} 2>/dev/null; then
        echo "Installed FFmpeg runtime codec libs from manifest: ${_ff_pkgs}"
      else
        echo "Batch ffmpeg runtime-lib install failed; retrying best-effort per package"
        local _ff_pkg
        for _ff_pkg in ${_ff_pkgs}; do
          apt-get install -y --no-install-recommends "${_ff_pkg}" >/dev/null 2>&1 \
            || echo "  (best-effort: ${_ff_pkg} unavailable for this arch, skipped)"
        done
      fi
    fi
  else
    echo "No /opt/ffmpeg/runtime-apt-packages.txt manifest; relying on the hardcoded codec-lib baseline"
  fi
}

# Fail-loud gate: every shared library the shipped ffmpeg needs (its full
# transitive closure) MUST resolve on the runtime loader path. The codec-lib
# installs above are best-effort, and historically a silently-skipped package
# (e.g. libopencore-amrwb0 -> libopencore-amrwb.so.0) shipped undetected --
# ffmpeg then died at load on arm64/riscv64 while amd64 stayed green, and the
# only backstop (the runtime-image ffmpeg smoke) is skipped whenever binfmt/QEMU
# is absent. `ldd` honours the LD_LIBRARY_PATH exported by setup_torch_deps (so
# /opt/ffmpeg's own libav* resolve too) and runs natively in this torch stage
# under QEMU, so this asserts the property that actually matters regardless of
# smoke gating. Escape hatch: ALLOW_BROKEN_FFMPEG=1.
_assert_ffmpeg_so_closure() {
  if [ -x /opt/ffmpeg/bin/ffmpeg ] && command -v ldd >/dev/null 2>&1; then
    local _ff_unresolved
    _ff_unresolved="$(ldd /opt/ffmpeg/bin/ffmpeg 2>/dev/null | awk '/=> not found/{print $1}' | sort -u || true)"
    if [ -n "${_ff_unresolved}" ]; then
      echo "FATAL: /opt/ffmpeg/bin/ffmpeg has unresolved shared libraries on the runtime loader path:" >&2
      printf '  %s (not found)\n' ${_ff_unresolved} >&2
      echo "  Install the providing apt package(s) in setup_torch_deps or via the ffmpeg runtime-apt manifest (emit_runtime_apt_manifest)." >&2
      if [ "${ALLOW_BROKEN_FFMPEG:-0}" = "1" ]; then
        echo "WARNING: ALLOW_BROKEN_FFMPEG=1 -- shipping ffmpeg with unresolved libraries anyway." >&2
      else
        rm -rf /var/lib/apt/lists/*
        exit 1
      fi
    else
      echo "FFmpeg shared-library closure fully resolved on the runtime loader path"
    fi
  fi
}

setup_torch_deps() {
  cross_skip "torch environment assembly" && return 0

  # Register /opt library paths so Python imports (and the ldd closure gate below)
  # find FFmpeg etc. Exported so it reaches the helper subshells and ldd/apt.
  export LD_LIBRARY_PATH="/usr/local/lib:/opt/opencv5/lib:/opt/gstreamer/lib:/opt/libcamera/lib:/opt/ffmpeg/lib:${LD_LIBRARY_PATH:-}"

  apt-get update
  _install_cv2_runtime_apt
  _install_ffmpeg_runtime_codecs
  _assert_ffmpeg_so_closure

  rm -rf /var/lib/apt/lists/*
}

seed_riscv64_apt_packages() {
  # ---- riscv64/QEMU-specific bootstrap (arch bootstrap, NOT wheel logic) ----
  # RISC-V has almost no pre-built Python wheels on PyPI.  Seed the C-extension
  # packages that would otherwise force a source build (or that a verify step
  # hard-imports) from apt into the venv.  cairo/gi/contourpy are copied WITH
  # their dist-info/egg-info so uv recognises them as already-installed and skips
  # them.  python3-contourpy is best-effort (assemble-torch-app's verify step
  # hard-imports contourpy and no riscv64 wheel exists on PyPI).
  #
  # numpy is deliberately NOT seeded into the venv: the resolved set pins a newer
  # numpy than apt ships, so uv builds that version regardless. If the apt numpy
  # tree were copied in (it has no dist-info uv trusts), uv would still build the
  # pinned wheel and then fail to INSTALL it -- "failed to create directory
  # numpy/random/lib: File exists" -- colliding with the seeded files. numpy now
  # builds cleanly under QEMU (see the -idirafter header fix above), so let uv
  # build + install it into a clean site-packages. python3-numpy is still apt-
  # installed below as a dependency of the cairo/gi/contourpy stack.
  apt-get update
  apt-get install -y --no-install-recommends python3-numpy python3-cairo python3-gi python3-gi-cairo
  apt-get install -y --no-install-recommends python3-contourpy \
    || echo "WARNING: python3-contourpy not available via apt"
  # The riscv64 torch wheel is cross-built with USE_SYSTEM_SLEEF=1
  # (build-app-wheelhouse.sh _torch_detect_system_sleef): PyTorch links
  # libsleef.so.3 dynamically instead of bundling SLEEF, and the cross-build
  # path deliberately skips auditwheel-repair (repair-wheels.sh), so the .so is
  # never vendored into the wheel. Install the SLEEF runtime lib (libsleef-dev's
  # runtime half, same Ubuntu release as the build sysroot) so `import torch`
  # can resolve libsleef.so.3 -- without it the venv torch fails to import.
  apt-get install -y --no-install-recommends libsleef3 \
    || echo "WARNING: libsleef3 unavailable via apt; import torch will fail (libsleef.so.3 missing)"
  rm -rf /var/lib/apt/lists/*
  local _sp
  _sp="$(venv_site_packages)"
  if [ -d /usr/lib/python3/dist-packages ] && [ -n "${_sp}" ] && [ -d "${_sp}" ]; then
    for pkg in cairo gi contourpy PyGObject-*.egg-info pycairo-*.egg-info contourpy-*.egg-info contourpy-*.dist-info; do
      cp -a /usr/lib/python3/dist-packages/"${pkg}" "${_sp}/" 2>/dev/null || true
    done
    echo "Seeded apt Python packages into venv (QEMU riscv64 mode)"
  fi
}

torch_wheel_missing_fallback() {
  # ---- Documented fallback: wheelhouse shipped no torch wheel ----
  # The media app-wheelhouse stage is best-effort: when the cross
  # torch/torchvision wheel builds fail (or the media image was a stale
  # cache-hit predating torch wheels), /opt/wheels carries no torch
  # wheel.  Routing through assemble-torch-app.sh would then leave torch
  # out of the locked-local set, so uv would resolve UPSTREAM torch from
  # PyPI — which has no riscv64 wheels — and the sdist build dies under
  # QEMU.  Keep the historic lightweight path instead: install the local
  # OpenCV wheel (or copy the source-built cv2 from /opt/opencv5) and
  # stop after an import check.
  local arch="${1:-$(uname -m)}"
  local opencv_wheel
  opencv_wheel="$(ls /opt/wheels/opencv_contrib_python-*.whl 2>/dev/null | head -1 || true)"
  if [ -n "${opencv_wheel}" ]; then
    "${VENV}/bin/pip" install --no-deps "${opencv_wheel}"
  elif [ -d /opt/opencv5/lib ]; then
    local cv2_src
    cv2_src="$(find /opt/opencv5/lib -maxdepth 3 -name cv2 -type d 2>/dev/null | head -1 || true)"
    local _sp
    _sp="$(venv_site_packages)"
    if [ -n "${cv2_src}" ] && [ -n "${_sp}" ]; then
      cp -a "${cv2_src}" "${_sp}/" 2>/dev/null || true
    fi
  fi
  if "${VENV}/bin/python" -c "import cv2; print('cv2', cv2.__version__)" 2>/dev/null; then
    echo "cv2 import OK"
  else
    echo "WARNING: cv2 not available (cross-compiled OpenCV may lack Python bindings for riscv64)"
  fi
  # LOUD, assertable marker: this image ships WITHOUT torch. Without it the
  # degradation is silent -- a torch-less riscv64 runtime image looks identical
  # to a good one until something imports torch on real hardware. Drop a sentinel
  # so smoke-runtime-image.sh can surface it and a torch-less image can't pass
  # unnoticed. Set ALLOW_TORCHLESS_RUNTIME=1 to accept it knowingly.
  mkdir -p "${VENV}" 2>/dev/null || true
  printf '%s: no torch wheel in /opt/wheels at build time; assemble-torch-app.sh skipped\n' \
    "${arch}" > "${VENV}/.torch-missing" 2>/dev/null || true
  {
    echo "############################################################"
    echo "WARNING: SHIPPING ${arch} RUNTIME IMAGE WITHOUT PYTORCH"
    echo "  (no torch wheel in /opt/wheels; app assembly was skipped)"
    echo "  Sentinel: ${VENV}/.torch-missing -- runtime smoke will flag it."
    echo "############################################################"
  } >&2
  echo "${arch} fallback venv ready (no torch wheel in /opt/wheels; skipped app assembly)"
}

# Fail-fast preflight: the relocated native GCC/G++ used for source builds under
# QEMU has repeatedly been unable to find the runtime image's system headers —
# C `string.h`, and C++ `<cstdlib>` -> `#include_next <stdlib.h>` — and Pillow's
# JPEG support needs `jpeglib.h` (libjpeg-dev). Each of those was discovered only
# after a ~9-min numpy/pillow compile died. Probe all three here in <1s using the
# SAME compiler + CPPFLAGS/CFLAGS/CXXFLAGS the pip build will use, so a
# header/sysroot regression aborts immediately with a clear message.
# See docs/cross-build-verification.md (failure classes 2 & 3).
verify_native_source_headers() {
  local cc="${CC:-gcc}" cxx="${CXX:-g++}" tmp rc=0
  command -v "${cc}" >/dev/null 2>&1 || cc=gcc
  command -v "${cxx}" >/dev/null 2>&1 || cxx=g++
  tmp="$(mktemp -d)"
  printf '#include <string.h>\nint main(void){return (int)strlen("");}\n' > "${tmp}/t.c"
  printf '#include <cstdlib>\n#include <string>\nint main(){std::string s; return std::atoi("0")+(int)s.size();}\n' > "${tmp}/t.cpp"
  printf '#include <stdio.h>\n#include <jpeglib.h>\nint main(void){struct jpeg_decompress_struct c; (void)c; return 0;}\n' > "${tmp}/j.c"
  # shellcheck disable=SC2086  # intentional word-splitting of the *FLAGS vars
  "${cc}"  ${CPPFLAGS:-} ${CFLAGS:-}   "${tmp}/t.c"   -o "${tmp}/t_c"   2>"${tmp}/c.err"   || { echo "PREFLIGHT FAIL: native C compile cannot find system headers (e.g. string.h)" >&2; sed 's/^/    /' "${tmp}/c.err" >&2; rc=1; }
  # shellcheck disable=SC2086
  "${cxx}" ${CPPFLAGS:-} ${CXXFLAGS:-} "${tmp}/t.cpp" -o "${tmp}/t_cpp" 2>"${tmp}/cpp.err" || { echo "PREFLIGHT FAIL: native C++ compile cannot resolve libstdc++ #include_next (<cstdlib> -> stdlib.h)" >&2; sed 's/^/    /' "${tmp}/cpp.err" >&2; rc=1; }
  # shellcheck disable=SC2086
  "${cc}"  ${CPPFLAGS:-} ${CFLAGS:-}   "${tmp}/j.c"   -c -o "${tmp}/j.o" 2>"${tmp}/j.err"   || { echo "PREFLIGHT FAIL: jpeglib.h not usable (Pillow JPEG support needs libjpeg-dev)" >&2; sed 's/^/    /' "${tmp}/j.err" >&2; rc=1; }
  rm -rf "${tmp}"
  if [ "${rc}" -ne 0 ]; then
    echo "Native source-build preflight FAILED with ${cc}/${cxx}; CPPFLAGS='${CPPFLAGS:-}' CXXFLAGS='${CXXFLAGS:-}'" >&2
    return 1
  fi
  echo "Native source-build preflight OK (C string.h, C++ #include_next stdlib.h, jpeglib.h) via ${cc}/${cxx}"
}

configure_foreign_arch_compiler_env() {
  local host_arch="$1"
  if [ "${host_arch}" != "x86_64" ]; then
    export CC=/opt/gcc-${GCC_VERSION:-16.2.0}/bin/gcc
    export CXX=/opt/gcc-${GCC_VERSION:-16.2.0}/bin/g++
    unset CC_LD CXX_LD RUSTC_WRAPPER SCCACHE_RECACHE
    echo "sccache bypass: CC=${CC} CXX=${CXX} (host ${host_arch})"
    # Abort now (seconds) rather than after a multi-minute source build if the
    # native compiler cannot resolve system headers for this target.
    verify_native_source_headers || exit 1
    local _sp
    _sp="$(venv_site_packages)"
    if [ -d /usr/lib/python3/dist-packages ] && [ -n "${_sp}" ] && [ -d "${_sp}" ]; then
      cp -a /usr/lib/python3/dist-packages/cairo     "${_sp}/" 2>/dev/null || true
      cp -a /usr/lib/python3/dist-packages/pycairo-*.egg-info "${_sp}/" 2>/dev/null || true
      echo "Copied system pycairo into venv"
    fi
  fi
}

apply_torch_app_env_defaults() {
  : "${ONNX_PACKAGE:=onnxruntime}"
  : "${PYTORCH_EXTRA:=pytorch-cpu}"
  : "${SKIP_TORCH_TEST_EXTRAS:=true}"
  export ONNX_PACKAGE PYTORCH_EXTRA SKIP_TORCH_TEST_EXTRAS
}

pin_pycairo_constraint_for_foreign_arch() {
  local host_arch="$1"
  if [ "${host_arch}" != "x86_64" ]; then
    local constraint_file
    constraint_file="$(mktemp)"
    echo "pycairo==1.27.0" > "${constraint_file}"
    export PIP_CONSTRAINT="${constraint_file}"
    export UV_CONSTRAINT="${constraint_file}"
    echo "Pinned pycairo to 1.27.0 via constraint ${constraint_file}"
  fi
}

setup_torch_app() {
  cross_skip "torch application install" && return 0

  local host_arch
  host_arch="$(uname -m)"

  # riscv64 is special: upstream ships no riscv64 torch wheels, so torch is a
  # LOCAL cross-built wheel in /opt/wheels (media app-wheelhouse, riscv64-only). If
  # that wheel is absent the shared assemble path would resolve UPSTREAM torch and
  # die under QEMU, so keep the tolerated lightweight fallback (writes the
  # .torch-missing sentinel). amd64/arm64 do NOT get a local torch wheel -- torch
  # is a normal resolved dependency installed by assemble-torch-app's `uv sync`
  # (the ml-ai extra) -- so they must NOT be gated on a local wheel.
  if [ "${host_arch}" = "riscv64" ]; then
    seed_riscv64_apt_packages
    if ! compgen -G "/opt/wheels/torch-*.whl" >/dev/null; then
      torch_wheel_missing_fallback "${host_arch}"
      return 0
    fi
    echo "riscv64 torch wheel present in /opt/wheels; routing through assemble-torch-app.sh"
  fi

  configure_foreign_arch_compiler_env "${host_arch}"

  apply_torch_app_env_defaults
  pin_pycairo_constraint_for_foreign_arch "${host_arch}"
  /opt/scripts/03-media/final/assemble-torch-app.sh "${TORCH_APP_MODE}"

  verify_torch_import_or_fail "${host_arch}"
}

verify_torch_import_or_fail() {
  # Fail FAST at packaging if torch is expected but did not land in the venv.
  # torch on amd64/arm64 comes from `uv sync`, not a local wheel, so a silent
  # uv-sync failure (e.g. the `--extra none` bug, or lock/index trouble) drops it
  # without any local-wheel signal -- and the ONLY thing that caught it before was
  # the runtime smoke ~5h into the build (2026-07-11). This import check turns that
  # into an immediate packaging failure. riscv64 already returned above when it has
  # no wheel; here it just double-confirms.
  local host_arch="$1" ver _import_err
  # Run the import from a NEUTRAL directory (/). On riscv64 the env-gate strip
  # (assemble-torch-app) makes uv fetch the pytorch git source, which can leave a
  # pytorch-repo `torch/` source tree in the working directory. `python -c` puts
  # CWD on sys.path[0], so importing from there loads that source `torch/` (whose
  # `torch/_C` is a plain folder, not the compiled extension) and torch dies with
  # "Failed to load PyTorch C extensions". `cd /` guarantees the installed
  # site-packages torch wins. Harmless on amd64/arm64 (import works from anywhere).
  if ver="$(cd / && "${VENV}/bin/python" -c 'import torch; print(torch.__version__)' 2>/dev/null)"; then
    echo "torch import OK (${ver}, ${host_arch})"
    return 0
  fi
  # Capture the ACTUAL import error (previously swallowed by 2>/dev/null) so a real
  # runtime failure (missing .so, ABI skew, C-extension shadowing) is named here
  # instead of forcing blind QEMU archaeology. Also from the neutral dir.
  _import_err="$(cd / && "${VENV}/bin/python" -c 'import torch' 2>&1 || true)"
  if [ "${ALLOW_TORCHLESS_RUNTIME:-0}" = "1" ]; then
    mkdir -p "${VENV}" 2>/dev/null || true
    printf '%s: torch not importable after assemble-torch-app; ALLOW_TORCHLESS_RUNTIME=1\n' \
      "${host_arch}" > "${VENV}/.torch-missing" 2>/dev/null || true
    echo "WARNING: torch not importable but ALLOW_TORCHLESS_RUNTIME=1 -- shipping torch-less (sentinel written)" >&2
    return 0
  fi
  {
    echo "ERROR: torch is not importable in ${VENV} after assemble-torch-app (${host_arch})."
    echo "  torch is expected here (installed by uv sync via the ml-ai extra). A silent"
    echo "  uv-sync failure most likely dropped it -- scan the assemble output above for"
    echo "  'uv sync ... had issues' or 'Extra ... is not defined'. Set"
    echo "  ALLOW_TORCHLESS_RUNTIME=1 to knowingly ship a torch-less image."
    echo "  ---- actual 'import torch' error ----"
    printf '  %s\n' "${_import_err:-(no output captured)}"
    echo "  -------------------------------------"
  } >&2
  exit 1
}

cleanup_wheelhouse() {
  # /opt/wheels (copied into the package image from the media stage) is only
  # consumed during venv assembly — by this script and assemble-torch-app.sh
  # (--find-links /opt/wheels + locked local wheel installs).  Nothing later
  # in the image lifecycle reads it (the HEALTHCHECK imports onnxruntime from
  # the venv; the runtime entrypoint scripts never touch /opt/wheels), so
  # keeping it only bloats the final torch image.  Set KEEP_WHEELHOUSE=1 to
  # preserve it for debugging.
  if [ "${BUILD_MODE}" = "cross" ]; then
    echo "Keeping /opt/wheels (pure cross artifact mode; venv assembly deferred)"
    return 0
  fi
  if [ "${KEEP_WHEELHOUSE:-0}" = "1" ]; then
    echo "Keeping /opt/wheels (KEEP_WHEELHOUSE=1)"
    return 0
  fi
  rm -rf /opt/wheels
  echo "Removed /opt/wheels after successful venv assembly (set KEEP_WHEELHOUSE=1 to keep)"
}

main() {
  setup_torch_venv
  seed_opencv5_bindings
  setup_torch_deps
  setup_torch_app
  cleanup_wheelhouse
}

main "$@"
