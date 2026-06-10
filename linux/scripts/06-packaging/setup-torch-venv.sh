#!/usr/bin/env bash
set -euo pipefail

# setup-torch-venv.sh
# Consolidated torch venv creation and application assembly for Dockerfile.torch.
# Replaces the three separate RUN blocks that duplicate the cross-mode skip guard.

TORCH_APP_MODE="${TORCH_APP_MODE:-all}"
VENV="${VENV:-/opt/venv}"
BUILD_MODE="${BUILD_MODE:-native}"

cross_skip() {
  if [ "${BUILD_MODE}" = "cross" ]; then
    echo "Skipping ${1:-torch step} in pure cross artifact mode"
    return 0
  fi
  return 1
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
    site_pkg_dir="$(echo "${VENV}/lib/python3."*/site-packages 2>/dev/null | head -1 || true)"
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

setup_torch_deps() {
  cross_skip "torch environment assembly" && return 0

  apt-get update
  # The locally-built OpenCV python wheel (opencv-contrib-python) in /opt/wheels is
  # a plain linux_x86_64 wheel (not manylinux): it bundles nothing and dynamically
  # links the full system stack plus the source-built ffmpeg in /opt/ffmpeg. The
  # ffmpeg libs in turn pull external codec runtime libraries that are NOT part of
  # the GTK/GLib stack and are not otherwise installed in the runtime image. The
  # block below (libtbb12 .. libgraphene-1.0-0) provides exactly the sonames that
  # `ldd` reports as unresolved for cv2.abi3.so once /opt payload dirs are on the
  # loader path. Removing any of them breaks `import cv2` in the torch venv.
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
    libfdk-aac2 libmp3lame0 libopus0 libvorbis0a libvorbisenc2 \
    libass9 libsndio7.0 libopenexr-3-1-30 libgraphene-1.0-0
  rm -rf /var/lib/apt/lists/*
}

setup_torch_app() {
  cross_skip "torch application install" && return 0

  local host_arch
  host_arch="$(uname -m)"
  if [ "${host_arch}" = "riscv64" ]; then
    # RISC-V has almost no pre-built Python wheels on PyPI; every
    # sdist build fails under QEMU because the GCC driver cannot fork
    # cc1/as.  Install numpy + pycairo + PyGObject via apt, seed them
    # into the venv, and skip the pip application assembly altogether
    # (just verify cv2 imports).
    apt-get update
    apt-get install -y --no-install-recommends python3-numpy python3-cairo python3-gi python3-gi-cairo
    rm -rf /var/lib/apt/lists/*
    if [ -d /usr/lib/python3/dist-packages ] && [ -d "${VENV}/lib/python3."*/site-packages ]; then
      for pkg in numpy cairo gi PyGObject-*.egg-info pycairo-*.egg-info; do
        cp -a /usr/lib/python3/dist-packages/"${pkg}" "${VENV}/lib/python3."*/site-packages/ 2>/dev/null || true
      done
      echo "Seeded apt Python packages into venv (QEMU riscv64 mode)"
    fi
    # OpenCV Python bindings may not have a pre-built wheel in /opt/wheels
    # for riscv64 (cross-compiled OpenCV puts them in /opt/opencv5).
    # Copy the cv2 module from the system OpenCV installation if no wheel
    # exists, then verify.
    local opencv_wheel
    opencv_wheel="$(ls /opt/wheels/opencv_contrib_python-*.whl 2>/dev/null | head -1 || true)"
    if [ -n "${opencv_wheel}" ]; then
      "${VENV}/bin/pip" install --no-deps "${opencv_wheel}"
    elif [ -d /opt/opencv5/lib ]; then
      local cv2_src
      cv2_src="$(find /opt/opencv5/lib -maxdepth 3 -name cv2 -type d 2>/dev/null | head -1 || true)"
      if [ -n "${cv2_src}" ]; then
        cp -a "${cv2_src}" "${VENV}/lib/python3."*/site-packages/ 2>/dev/null || true
      fi
    fi
    if "${VENV}/bin/python" -c "import cv2; print('cv2', cv2.__version__)" 2>/dev/null; then
      echo "cv2 import OK"
    else
      echo "WARNING: cv2 not available (cross-compiled OpenCV may lack Python bindings for riscv64)"
    fi
    echo "riscv64 torch venv ready (apt packages + local wheel/opencv5)"
    return 0
  fi

  if [ "${host_arch}" != "x86_64" ]; then
    export CC=/opt/gcc-${GCC_VERSION:-16.1.0}/bin/gcc
    export CXX=/opt/gcc-${GCC_VERSION:-16.1.0}/bin/g++
    unset CC_LD CXX_LD RUSTC_WRAPPER SCCACHE_RECACHE
    echo "sccache bypass: CC=${CC} CXX=${CXX} (host ${host_arch})"
    if [ -d /usr/lib/python3/dist-packages ] && [ -d "${VENV}/lib/python3."*/site-packages ]; then
      cp -a /usr/lib/python3/dist-packages/cairo     "${VENV}/lib/python3."*/site-packages/ 2>/dev/null || true
      cp -a /usr/lib/python3/dist-packages/pycairo-*.egg-info "${VENV}/lib/python3."*/site-packages/ 2>/dev/null || true
      echo "Copied system pycairo into venv"
    fi
  fi

  export SKIP_TORCH_TEST_EXTRAS=true
  if [ "${host_arch}" != "x86_64" ]; then
    local constraint_file
    constraint_file="$(mktemp)"
    echo "pycairo==1.27.0" > "${constraint_file}"
    export PIP_CONSTRAINT="${constraint_file}"
    export UV_CONSTRAINT="${constraint_file}"
    echo "Pinned pycairo to 1.27.0 via constraint ${constraint_file}"
  fi
  /opt/scripts/media/final/assemble-torch-app.sh "${TORCH_APP_MODE}"
}

main() {
  setup_torch_venv
  seed_opencv5_bindings
  setup_torch_deps
  setup_torch_app
}

main "$@"
