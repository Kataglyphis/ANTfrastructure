#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /opt/scripts/core/platform.sh

link_path_if_present() {
    local candidate="$1"
    local link_path="$2"

    if [ -n "${candidate}" ] && [ "${candidate}" != "${link_path}" ]; then
        ln -sf "${candidate}" "${link_path}"
    fi
}

# shellcheck disable=SC1091
source /opt/scripts/core/package-lists.sh

link_command_if_present() {
    local command_name="$1"
    local link_path="$2"
    local command_path

    command_path="$(command -v "${command_name}" || true)"
    link_path_if_present "${command_path}" "${link_path}"
}

add_prefix_python_paths_to_venv() {
    local prefix="$1"
    local venv_python="$2"
    local site_packages_dir=""
    local pth_path=""
    local dir
    local -a python_paths=()

    [ -d "${prefix}" ] || return 0

    site_packages_dir="$("${venv_python}" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || true)"
    [ -n "${site_packages_dir}" ] || return 0

    shopt -s nullglob
    for dir in \
        "${prefix}"/lib/python3*/site-packages \
        "${prefix}"/lib/python3*/dist-packages \
        "${prefix}"/lib64/python3*/site-packages \
        "${prefix}"/lib64/python3*/dist-packages \
        "${prefix}"/python/cv2/python-*; do
        [ -d "${dir}" ] || continue
        python_paths+=("${dir}")
    done
    shopt -u nullglob

    [ "${#python_paths[@]}" -gt 0 ] || return 0

    pth_path="${site_packages_dir}/kataglyphis-opencv-system-paths.pth"
    mkdir -p "${site_packages_dir}"
    : > "${pth_path}"
    for dir in "${python_paths[@]}"; do
        printf '%s\n' "${dir}" >> "${pth_path}"
    done
}

# Install the source-built target Python (staged at /opt/python-cross by the
# cross build) into /usr/local, if present for this arch.
install_staged_target_python() {
    local python_mm="$1"
    local target_arch="${TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
    local staged_python_root="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${target_arch}"

    case "$(arch_normalize "${target_arch}")" in
        amd64|arm64|riscv64)
            if [ -x "${staged_python_root}/usr/local/bin/python${python_mm}" ]; then
                echo "Installing source-built target Python ${python_mm} from ${staged_python_root}/usr/local"
                cp -a "${staged_python_root}/usr/local/bin"/* /usr/local/bin/
                cp -a "${staged_python_root}/usr/local/lib"/python"${python_mm}" /usr/local/lib/
                cp -a "${staged_python_root}/usr/local/lib"/libpython* /usr/local/lib/
                cp -a "${staged_python_root}/usr/local/lib"/pkgconfig /usr/local/lib/
                cp -a "${staged_python_root}/usr/local/include"/python* /usr/local/include/
                echo "/usr/local/lib" > "/etc/ld.so.conf.d/python-local.conf"
                ldconfig
            fi
            ;;
    esac
}

# Choose the dev/runtime apt packages (python-dev, matching gcc/g++, llvm/clang
# extras) based on what's available, then install them.
select_and_install_dev_packages() {
    local python_mm="$1" gcc_major="$2"
    local -a packages=(libtbb-dev python3-venv python3-pip cargo rustc)

    if [ ! -x "/usr/local/bin/python${python_mm}" ]; then
        if apt_package_exists "python${python_mm}-dev"; then
            packages+=("python${python_mm}-dev")
        elif apt_package_exists python3-dev; then
            packages+=(python3-dev)
        fi
    fi

    if apt_package_exists "gcc-${gcc_major}" && apt_package_exists "g++-${gcc_major}"; then
        packages+=("gcc-${gcc_major}" "g++-${gcc_major}")
    fi

    append_available_packages packages clang-22 lld-22 llvm-22 llvm-22-dev \
        libclang-rt-22-dev libfuzzer-22-dev cargo-c

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"

    # The shipped clang{,++} MUST equal LLVM_RELEASE (asserted by the runtime
    # clang-version smoke). Two candidate toolchains can provide it:
    #   1. /usr/local/llvm-target  — the source-built target clang. For arm64/riscv64
    #      this is cross-built to exactly LLVM_RELEASE. For amd64 it is a COPY of the
    #      compiler stage's apt clang, which LAGS if that (heavy, long-cached) layer
    #      was baked before apt.llvm.org published the point release (e.g. ships 22.1.2
    #      while LLVM_RELEASE=22.1.8).
    #   2. /usr/lib/llvm-<major>   — the apt clang-<major> just (re)installed in THIS
    #      freshly apt-updated package stage. Once apt.llvm.org catches up it is exactly
    #      LLVM_RELEASE, which rescues amd64 without rebuilding the compiler layer.
    # Pin whichever candidate's version == LLVM_RELEASE, PREFERRING the source toolchain
    # (so arm64/riscv64 keep their cross-built clang); fall back to the first present
    # candidate if neither matches (better a working clang than none). The apt clang-<major>
    # package is retained regardless for its libLLVM/libclang dev libs.
    local _want_llvm _llvm_major _cand _chosen=""
    _want_llvm="${LLVM_RELEASE:-}"
    if [ -z "${_want_llvm}" ] && [ -f /opt/scripts/core/versions.env ]; then
        _want_llvm="$( . /opt/scripts/core/versions.env 2>/dev/null; printf '%s' "${LLVM_RELEASE:-}" )"
    fi
    _llvm_major="${_want_llvm%%.*}"
    _clang_ver() {
        "$1" --version 2>/dev/null \
            | grep -oiE 'clang version [0-9]+\.[0-9]+\.[0-9]+' \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    }
    for _cand in /usr/local/llvm-target "/usr/lib/llvm-${_llvm_major}"; do
        [ -x "${_cand}/bin/clang" ] || continue
        [ -n "${_chosen}" ] || _chosen="${_cand}"   # fallback = first present (source preferred)
        if [ -n "${_want_llvm}" ] && [ "$(_clang_ver "${_cand}/bin/clang")" = "${_want_llvm}" ]; then
            _chosen="${_cand}"; break
        fi
    done

    if [ -n "${_chosen}" ] && [ -x "${_chosen}/bin/clang" ]; then
        update-alternatives --install /usr/bin/clang clang "${_chosen}/bin/clang" 1000 \
            --slave /usr/bin/clang++ clang++ "${_chosen}/bin/clang++" 2>/dev/null || true
        update-alternatives --set clang "${_chosen}/bin/clang" 2>/dev/null || true
        # Belt-and-suspenders: if the apt package installed plain symlinks that
        # alternatives did not adopt, point them at the chosen toolchain directly.
        [ "$(readlink -f /usr/bin/clang 2>/dev/null)" = "$(readlink -f "${_chosen}/bin/clang")" ] || \
            ln -sf "${_chosen}/bin/clang" /usr/bin/clang
        [ -x "${_chosen}/bin/clang++" ] && \
            { [ "$(readlink -f /usr/bin/clang++ 2>/dev/null)" = "$(readlink -f "${_chosen}/bin/clang++")" ] || \
              ln -sf "${_chosen}/bin/clang++" /usr/bin/clang++; }
        echo "[INFO] Pinned /usr/bin/clang -> $(readlink -f /usr/bin/clang) ($(/usr/bin/clang --version 2>/dev/null | head -1)); wanted LLVM_RELEASE=${_want_llvm:-<unset>}"
    fi
}

# Wire /usr/local python/pip/config + libpython symlinks (and create the dirs
# the cargo/venv phases below rely on).
wire_python_symlinks() {
    local python_mm="$1"
    local python_bin python_cfg pip_bin triplet lib

    python_bin="$(command -v "python${python_mm}" || command -v python3)"
    python_cfg="$(command -v "python${python_mm}-config" || true)"
    pip_bin="$(command -v "pip${python_mm}" || command -v pip3 || true)"
    triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH)"

    mkdir -p /usr/local/bin /usr/local/lib "${VIRTUAL_ENV%/*}" "${CARGO_HOME}/bin" "${RUSTUP_HOME}"
    link_path_if_present "${python_bin}" "/usr/local/bin/python${python_mm}"
    link_path_if_present "${python_bin}" /usr/local/bin/python3
    link_path_if_present "${python_bin}" /usr/local/bin/python

    if [ -n "${python_cfg}" ]; then
        link_path_if_present "${python_cfg}" "/usr/local/bin/python${python_mm}-config"
    fi

    if [ -n "${pip_bin}" ]; then
        link_path_if_present "${pip_bin}" "/usr/local/bin/pip${python_mm}"
        link_path_if_present "${pip_bin}" /usr/local/bin/pip3
        link_path_if_present "${pip_bin}" /usr/local/bin/pip
    fi

    for lib in \
        "/usr/lib/${triplet}/libpython${python_mm}.so" \
        "/usr/lib/${triplet}/libpython${python_mm}.so.1.0" \
        "/usr/lib/libpython${python_mm}.so" \
        "/usr/lib/libpython${python_mm}.so.1.0"; do
        [ -e "${lib}" ] || continue
        ln -sf "${lib}" "/usr/local/lib/$(basename "${lib}")"
    done
}

# If a custom source-built GCC is present, add its libs to the loader path.
preserve_custom_gcc() {
    local gcc_prefix="/opt/gcc-$1"

    if [ -f "${gcc_prefix}/bin/gcc" ]; then
        echo "Custom GCC already present at ${gcc_prefix}; preserving it."
        echo "${gcc_prefix}/lib64" > "/etc/ld.so.conf.d/gcc-custom.conf"
        echo "${gcc_prefix}/lib" >> "/etc/ld.so.conf.d/gcc-custom.conf"
        ldconfig
    fi
}

# Symlink the cargo/rust toolchain binaries into CARGO_HOME/bin.
wire_cargo_symlinks() {
    link_command_if_present cargo "${CARGO_HOME}/bin/cargo"
    link_command_if_present rustc "${CARGO_HOME}/bin/rustc"
    link_command_if_present rustdoc "${CARGO_HOME}/bin/rustdoc"
    link_command_if_present cargo-cbuild "${CARGO_HOME}/bin/cargo-cbuild"
    link_command_if_present cargo-cinstall "${CARGO_HOME}/bin/cargo-cinstall"
    link_command_if_present rustup "${CARGO_HOME}/bin/rustup"
}

# Create the runtime uv venv with build tooling. riscv64 can't run compiled
# wheels under QEMU, so it uses apt packages via --system-site-packages instead.
create_runtime_venv() {
    local python_mm="$1"

    rm -rf "${VIRTUAL_ENV}"
    uv venv --seed --python "/usr/local/bin/python${python_mm}" "${VIRTUAL_ENV}"
    if [ "${TARGET_ARCH:-}" = "riscv64" ] || [ "$(uname -m)" = "riscv64" ]; then
        # QEMU-riscv64 cannot run the gcc preprocessor, so compiled wheels
        # fail.  Install packages via apt (system-wide) and make them
        # visible to the venv via --system-site-packages.
        rm -rf "${VIRTUAL_ENV}"
        # NOTE: ml_dtypes for iree is NOT installed here via apt — python3-ml-dtypes
        # lands in the DISTRO python's /usr/lib/python3/dist-packages, which the
        # from-source CPython 3.14 venv (site under /usr/local/lib/python3.14) never
        # sees even with --system-site-packages. It is source-built into the venv in
        # assemble-torch-app.sh's riscv64 IREE branch instead.
        apt-get install -y --no-install-recommends \
            python3-numpy python3-meson python3-ninja python3-cmake \
            python3-wheel python3-setuptools python3-packaging 2>/dev/null || true
        uv venv --seed --system-site-packages --python "/usr/local/bin/python${python_mm}" "${VIRTUAL_ENV}"
        uv pip install --python "${VIRTUAL_ENV}/bin/python" wheel setuptools cmake packaging
    else
        uv pip install --python "${VIRTUAL_ENV}/bin/python" wheel setuptools numpy meson ninja cmake packaging
    fi
}

main() {
    local python_mm="${PYTHON_MAJOR_MINOR:?PYTHON_MAJOR_MINOR is required}"
    local gcc_major="${GCC_VERSION%%.*}"
    [ -n "${gcc_major}" ] || { echo "ERROR: GCC_VERSION is required" >&2; exit 1; }

    bash /opt/scripts/03-media/final/install-deps.sh
    apt-get update

    install_staged_target_python "${python_mm}"
    select_and_install_dev_packages "${python_mm}" "${gcc_major}"
    wire_python_symlinks "${python_mm}"
    preserve_custom_gcc "${GCC_VERSION}"
    wire_cargo_symlinks
    create_runtime_venv "${python_mm}"

    add_prefix_python_paths_to_venv "/opt/opencv5" "${VIRTUAL_ENV}/bin/python"

    bash /opt/scripts/03-media/final/configure-runtime.sh
    ldconfig
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

main "$@"
