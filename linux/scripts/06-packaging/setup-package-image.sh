#!/usr/bin/env bash
set -euxo pipefail

# shellcheck disable=SC1091
source /opt/scripts/core/package-lists.sh

link_command_if_present() {
    local command_name="$1"
    local link_path="$2"

    if command -v "${command_name}" >/dev/null 2>&1; then
        ln -sf "$(command -v "${command_name}")" "${link_path}"
    fi
}

main() {
    local python_mm="${PYTHON_MAJOR_MINOR:-3.14}"
    local gcc_major="${GCC_VERSION%%.*}"
    local python_bin python_cfg pip_bin triplet gcc_prefix
    local -a packages=(libtbb-dev python3-venv python3-pip cargo rustc)

    bash /opt/scripts/media/final/install-deps.sh
    apt-get update

    if apt_package_exists "python${python_mm}-dev"; then
        packages+=("python${python_mm}-dev")
    elif apt_package_exists python3-dev; then
        packages+=(python3-dev)
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
    ln -sf "${python_bin}" "/usr/local/bin/python${python_mm}"
    ln -sf "${python_bin}" /usr/local/bin/python3
    ln -sf "${python_bin}" /usr/local/bin/python

    if [ -n "${python_cfg}" ]; then
        ln -sf "${python_cfg}" "/usr/local/bin/python${python_mm}-config"
    fi

    if [ -n "${pip_bin}" ]; then
        ln -sf "${pip_bin}" "/usr/local/bin/pip${python_mm}"
        ln -sf "${pip_bin}" /usr/local/bin/pip3
        ln -sf "${pip_bin}" /usr/local/bin/pip
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
    mkdir -p "${gcc_prefix}/bin" "${gcc_prefix}/${triplet}"
    rm -rf "${gcc_prefix}/lib" "${gcc_prefix}/lib64" "${gcc_prefix}/${triplet}/lib"

    if [ -d "/usr/lib/${triplet}" ]; then
        ln -sfn "/usr/lib/${triplet}" "${gcc_prefix}/lib"
        ln -sfn "/usr/lib/${triplet}" "${gcc_prefix}/lib64"
        ln -sfn "/usr/lib/${triplet}" "${gcc_prefix}/${triplet}/lib"
    fi

    for tool in gcc g++ cpp gcov gcc-ar gcc-nm gcc-ranlib; do
        candidate="$(command -v "${tool}-${gcc_major}" || command -v "${tool}" || true)"
        [ -n "${candidate}" ] || continue
        ln -sf "${candidate}" "${gcc_prefix}/bin/${tool}"
    done

    for tool in gcc g++ cpp gcov gcc-ar gcc-nm gcc-ranlib ar as ld nm ranlib strip objcopy; do
        candidate="$(command -v "${triplet}-${tool}-${gcc_major}" || command -v "${triplet}-${tool}" || command -v "${tool}-${gcc_major}" || command -v "${tool}" || true)"
        [ -n "${candidate}" ] || continue
        ln -sf "${candidate}" "${gcc_prefix}/bin/${triplet}-${tool}"
    done

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

    bash /opt/scripts/media/final/configure-runtime.sh
    ldconfig
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

main "$@"
