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

main() {
    local python_mm="${PYTHON_MAJOR_MINOR:-3.14}"
    local gcc_major="${GCC_VERSION%%.*}"
    local python_bin python_cfg pip_bin triplet gcc_prefix
    local staged_python_root=""
    local -a packages=(libtbb-dev python3-venv python3-pip cargo rustc)

    bash /opt/scripts/media/final/install-deps.sh
    apt-get update

    staged_python_root="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
    case "$(arch_normalize "${TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}")" in
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
                echo "/usr/local/lib" >> /etc/ld.so.conf.d/python-local.conf
                ldconfig
            fi
            ;;
    esac

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

    gcc_prefix="/opt/gcc-${GCC_VERSION}"
    if [ -f "${gcc_prefix}/bin/gcc" ]; then
        echo "Custom GCC already present at ${gcc_prefix}; preserving it."
        echo "${gcc_prefix}/lib64" > "/etc/ld.so.conf.d/gcc-custom.conf"
        echo "${gcc_prefix}/lib" >> "/etc/ld.so.conf.d/gcc-custom.conf"
        ldconfig
    else
        # NOTE: This fallback is unreachable when built through Dockerfile.package
        # because the artifact-source stage hard-fails if GCC is missing from the
        # artifact image. Kept for standalone script usage outside Docker context.
        echo "WARNING: Custom GCC not found at ${gcc_prefix}; creating symlink fallback to system GCC."
        mkdir -p "${gcc_prefix}/bin" "${gcc_prefix}/${triplet}"
        rm -rf "${gcc_prefix}/lib" "${gcc_prefix}/lib64" "${gcc_prefix}/${triplet}/lib"

        if [ -d "/usr/lib/${triplet}" ]; then
            ln -sfn "/usr/lib/${triplet}" "${gcc_prefix}/lib"
            ln -sfn "/usr/lib/${triplet}" "${gcc_prefix}/lib64"
            ln -sfn "/usr/lib/${triplet}" "${gcc_prefix}/${triplet}/lib"
        fi

        for tool in gcc g++ cpp gcov gcc-ar gcc-nm gcc-ranlib; do
            candidate="$(command -v "${tool}-${gcc_major}" || command -v "${tool}" || true)"
            link_path_if_present "${candidate}" "${gcc_prefix}/bin/${tool}"
        done

        for tool in gcc g++ cpp gcov gcc-ar gcc-nm gcc-ranlib ar as ld nm ranlib strip objcopy; do
            candidate="$(command -v "${triplet}-${tool}-${gcc_major}" || command -v "${triplet}-${tool}" || command -v "${tool}-${gcc_major}" || command -v "${tool}" || true)"
            link_path_if_present "${candidate}" "${gcc_prefix}/bin/${triplet}-${tool}"
        done
    fi

    link_command_if_present cargo "${CARGO_HOME}/bin/cargo"
    link_command_if_present rustc "${CARGO_HOME}/bin/rustc"
    link_command_if_present rustdoc "${CARGO_HOME}/bin/rustdoc"
    link_command_if_present cargo-cbuild "${CARGO_HOME}/bin/cargo-cbuild"
    link_command_if_present cargo-cinstall "${CARGO_HOME}/bin/cargo-cinstall"
    link_command_if_present rustup "${CARGO_HOME}/bin/rustup"

    rm -rf "${VIRTUAL_ENV}"
    uv venv --seed --python "/usr/local/bin/python${python_mm}" "${VIRTUAL_ENV}"
    if [ "${TARGET_ARCH:-}" = "riscv64" ] || [ "$(uname -m)" = "riscv64" ]; then
        # QEMU-riscv64 cannot run the gcc preprocessor, so compiled wheels
        # fail.  Install packages via apt (system-wide) and make them
        # visible to the venv via --system-site-packages.
        rm -rf "${VIRTUAL_ENV}"
        apt-get install -y --no-install-recommends \
            python3-numpy python3-meson python3-ninja python3-cmake \
            python3-wheel python3-setuptools python3-packaging 2>/dev/null || true
        uv venv --seed --system-site-packages --python "/usr/local/bin/python${python_mm}" "${VIRTUAL_ENV}"
        uv pip install --python "${VIRTUAL_ENV}/bin/python" wheel setuptools cmake packaging
    else
        uv pip install --python "${VIRTUAL_ENV}/bin/python" wheel setuptools numpy meson ninja cmake packaging
    fi

    add_prefix_python_paths_to_venv "/opt/opencv4" "${VIRTUAL_ENV}/bin/python"

    bash /opt/scripts/media/final/configure-runtime.sh
    ldconfig
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

main "$@"
