#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /opt/scripts/core/platform.sh
# See docs/failure-modes.md § A packaging script dies with no message
# shellcheck source=linux/scripts/01-core/logging.sh
source /opt/scripts/core/logging.sh
install_err_trap

link_path_if_present() {
    local candidate="$1"
    local link_path="$2"

    if [ -n "${candidate}" ] && [ "${candidate}" != "${link_path}" ]; then
        ln -sf "${candidate}" "${link_path}"
    fi
}

# shellcheck disable=SC1091
source /opt/scripts/core/package-lists.sh
# The package stage's toolchain and runtime wiring (BACKLOG CON15, CON16, CON21).
# shellcheck source=linux/scripts/06-packaging/package-image-wiring.sh
source /opt/scripts/packaging/package-image-wiring.sh

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

# The source-built target Python the cross build stages at /opt/python-cross, if present.
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
            elif [ -e "${staged_python_root}" ]; then
                # Staged tree present but unusable: never fall through to the distro python.
                echo "ERROR: ${staged_python_root} exists but carries no executable usr/local/bin/python${python_mm}" >&2
                return 1
            else
                # Expected: Dockerfile.package stages none, so PYTHON_VERSION is not advertised.
                echo "No staged target Python at ${staged_python_root}; using the distro python${python_mm}."
            fi
            ;;
    esac
}

# The dev/runtime apt packages that exist here (python-dev, gcc/g++, llvm/clang extras).
select_dev_packages() {
    local -n _sdp_out=$1
    local python_mm="$2" gcc_major="$3"
    # Ubuntu's cargo/rustc come without rustup; report_rust_provenance says which toolchain won.
    _sdp_out=(libtbb-dev python3-venv python3-pip cargo rustc)

    if [ ! -x "/usr/local/bin/python${python_mm}" ]; then
        if apt_package_exists "python${python_mm}-dev"; then
            _sdp_out+=("python${python_mm}-dev")
        elif apt_package_exists python3-dev; then
            _sdp_out+=(python3-dev)
        fi
    fi

    if apt_package_exists "gcc-${gcc_major}" && apt_package_exists "g++-${gcc_major}"; then
        _sdp_out+=("gcc-${gcc_major}" "g++-${gcc_major}")
    fi

    # The major tracks LLVM_RELEASE for pin_clang_alternatives; 22 stays a floor, as absent packages are skipped.
    local _pkg_llvm_major
    _pkg_llvm_major="${LLVM_RELEASE%%.*}"
    [ -n "${_pkg_llvm_major}" ] || _pkg_llvm_major=22
    append_available_packages _sdp_out \
        "clang-${_pkg_llvm_major}" "lld-${_pkg_llvm_major}" \
        "llvm-${_pkg_llvm_major}" "llvm-${_pkg_llvm_major}-dev" \
        "libclang-rt-${_pkg_llvm_major}-dev" "libfuzzer-${_pkg_llvm_major}-dev"
    append_available_packages _sdp_out clang-22 lld-22 llvm-22 llvm-22-dev \
        libclang-rt-22-dev libfuzzer-22-dev cargo-c
    # What consumer lanes installed per run: lavapipe, perf (26.04's linux-perf), libprofiler, jq, Xvfb; ripgrep for searches.
    append_available_packages _sdp_out mesa-vulkan-drivers linux-perf \
        libgoogle-perftools-dev jq xvfb ripgrep

    # Never libgstreamer*-dev (ours is source-built, the distro one purged) or libgtk-4-dev (breaks cross builds).

    # Gradle needs a JDK; by name, since a silently skipped JDK ships an Android SDK that builds nothing.
    _sdp_out+=("${JDK_PACKAGE:?JDK_PACKAGE is required (01-core/versions.env)}")
}

# A JAVA_HOME that survives JDK bumps. See docs/consumer-image-contract.md § The Android lane needs a JDK
anchor_java_home() {
    local javac home
    javac="$(command -v javac 2>/dev/null || true)"
    [ -n "${javac}" ] || { echo "ERROR: ${JDK_PACKAGE:-the JDK} installed no javac; Gradle cannot build" >&2; return 1; }
    home="$(dirname "$(dirname "$(readlink -f "${javac}")")")"
    [ -x "${home}/bin/javac" ] || { echo "ERROR: resolved JAVA_HOME ${home} has no bin/javac" >&2; return 1; }
    mkdir -p /usr/lib/jvm
    ln -sfn "${home}" /usr/lib/jvm/default-java
    echo "OK: JAVA_HOME anchor /usr/lib/jvm/default-java -> ${home}"
}

install_dev_packages() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# A clang binary's version from its embedded DEB metadata, --version as the fallback.
clang_embedded_deb_version() {
    local _bin="$1" _ver=""
    # --version reports the runtime libclang-cpp, which apt's copy in /usr/lib shadows.
    _ver="$( strings "${_bin}" 2>/dev/null \
        | grep -o '"version":"[^"]*"' \
        | head -1 | tr -d \" | cut -d: -f3 | cut -d~ -f1 || true )"
    [ -n "${_ver}" ] && printf '%s' "${_ver}" && return 0
    _ver="$( "${_bin}" --version 2>/dev/null \
        | grep -oiE 'clang version [0-9]+\.[0-9]+\.[0-9]+' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 )"
    printf '%s' "${_ver}"
}

pin_clang_alternatives() {
    # clang must equal LLVM_RELEASE: the matching candidate wins, source first; amd64's copy can lag apt.
    local _want_llvm _llvm_major _cand _chosen=""
    _want_llvm="${LLVM_RELEASE:-}"
    if [ -z "${_want_llvm}" ] && [ -f /opt/scripts/core/versions.env ]; then
        _want_llvm="$( . /opt/scripts/core/versions.env 2>/dev/null; printf '%s' "${LLVM_RELEASE:-}" )"
    fi
    _llvm_major="${_want_llvm%%.*}"
    for _cand in /usr/local/llvm-target "/usr/lib/llvm-${_llvm_major}"; do
        [ -x "${_cand}/bin/clang" ] || continue
        [ -n "${_chosen}" ] || _chosen="${_cand}"   # fallback = first present (source preferred)
        if [ -n "${_want_llvm}" ] && [ "$(clang_embedded_deb_version "${_cand}/bin/clang")" = "${_want_llvm}" ]; then
            _chosen="${_cand}"; break
        fi
    done

    if [ -n "${_chosen}" ] && [ -x "${_chosen}/bin/clang" ]; then
        update-alternatives --install /usr/bin/clang clang "${_chosen}/bin/clang" 1000 \
            --slave /usr/bin/clang++ clang++ "${_chosen}/bin/clang++" 2>/dev/null || true
        update-alternatives --set clang "${_chosen}/bin/clang" 2>/dev/null || true
        # apt may leave plain symlinks that alternatives did not adopt.
        [ "$(readlink -f /usr/bin/clang 2>/dev/null)" = "$(readlink -f "${_chosen}/bin/clang")" ] || \
            ln -sf "${_chosen}/bin/clang" /usr/bin/clang
        [ -x "${_chosen}/bin/clang++" ] && \
            { [ "$(readlink -f /usr/bin/clang++ 2>/dev/null)" = "$(readlink -f "${_chosen}/bin/clang++")" ] || \
              ln -sf "${_chosen}/bin/clang++" /usr/bin/clang++; }
        echo "[INFO] Pinned /usr/bin/clang -> $(readlink -f /usr/bin/clang) ($(/usr/bin/clang --version 2>/dev/null | head -1)); wanted LLVM_RELEASE=${_want_llvm:-<unset>}"
    fi
}


# Also creates the dirs the cargo and venv phases rely on.
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

# Never overwrite rustup's shims: PATH finds apt's rustc first, so ln -sf would demote the pinned toolchain.
_link_unless_rustup_provides() {
    local command_name="$1" link_path="$2"

    if [ -e "${link_path}" ] || [ -L "${link_path}" ]; then
        echo "Keeping existing ${link_path} (rustup toolchain wins over PATH lookup)"
        return 0
    fi
    link_command_if_present "${command_name}" "${link_path}"
}

# See docs/failure-modes.md § The copied Rust toolchain is the builder's arch
ensure_native_rust_toolchain() {
    local triple
    triple="$(rust_target_triple_for_arch "$(dpkg --print-architecture)")" || return 0
    if compgen -G "${RUSTUP_HOME}/toolchains/*-${triple}" >/dev/null; then
        echo "Rust toolchain in ${RUSTUP_HOME} is native (${triple})"
        return 0
    fi
    echo "Rust toolchain in ${RUSTUP_HOME} is not ${triple}: $(ls "${RUSTUP_HOME}/toolchains" 2>/dev/null | tr '\n' ' ')-- reinstalling natively"
    # Spare ${CARGO_HOME}/registry: it is a live BuildKit cache mount, and rm over it fails EBUSY.
    rm -rf "${RUSTUP_HOME:?}"
    if [ -d "${CARGO_HOME:?}" ]; then
        find "${CARGO_HOME}" -mindepth 1 -maxdepth 1 ! -name registry -exec rm -rf {} +
    fi
    RUST_INSTALL_CARGO_C=0 BUILD_MODE=native bash /opt/scripts/toolchain/install-rust.sh
}

# Only what root owns: chown -R would copy whole trees up. See docs/artifact-copy-completeness.md § The rust toolchain must be writable by the runtime user
hand_root_created_paths_to_runtime_user() {
    local uid="${RUNTIME_UID:?}"
    find "$@" ! -user "${uid}" -exec chown -h "${uid}:${uid}" {} +
    echo "OK: $* owned by uid ${uid}"
}

wire_cargo_symlinks() {
    _link_unless_rustup_provides cargo "${CARGO_HOME}/bin/cargo"
    _link_unless_rustup_provides rustc "${CARGO_HOME}/bin/rustc"
    _link_unless_rustup_provides rustdoc "${CARGO_HOME}/bin/rustdoc"
    _link_unless_rustup_provides cargo-cbuild "${CARGO_HOME}/bin/cargo-cbuild"
    _link_unless_rustup_provides cargo-cinstall "${CARGO_HOME}/bin/cargo-cinstall"
    _link_unless_rustup_provides rustup "${CARGO_HOME}/bin/rustup"

    # Fail here: a skew otherwise surfaces days later as a consumer's MSRV error on some dependency.
    if [ -n "${RUST_VERSION:-}" ] && [ -x "${CARGO_HOME}/bin/rustc" ]; then
        local _got
        if ! _got="$("${CARGO_HOME}/bin/rustc" --version 2>&1)"; then
            echo "ERROR: ${CARGO_HOME}/bin/rustc does not execute: ${_got}" >&2
            echo "       A foreign-arch toolchain reaches here only if ensure_native_rust_toolchain did not replace it." >&2
            return 1
        fi
        _got="$(printf '%s\n' "${_got}" | awk '{print $2}')"
        if [ -n "${_got}" ] && [ "${_got}" != "${RUST_VERSION}" ]; then
            echo "ERROR: ${CARGO_HOME}/bin/rustc reports ${_got}, but RUST_VERSION pins ${RUST_VERSION}." >&2
            echo "       The pinned rustup toolchain is being shadowed - check that" >&2
            echo "       /usr/local/{rustup,cargo} were copied into this stage and that" >&2
            echo "       nothing relinked ${CARGO_HOME}/bin over them." >&2
            return 1
        fi
        echo "rustc ${_got} matches the pinned RUST_VERSION"
    fi
}

# riscv64 takes apt packages via --system-site-packages: compiled wheels fail under QEMU.
create_runtime_venv() {
    local python_mm="$1"

    rm -rf "${VIRTUAL_ENV}"
    uv venv --seed --python "/usr/local/bin/python${python_mm}" "${VIRTUAL_ENV}"
    if [ "${TARGET_ARCH:-}" = "riscv64" ] || [ "$(uname -m)" = "riscv64" ]; then
        # QEMU-riscv64 cannot run the gcc preprocessor.
        rm -rf "${VIRTUAL_ENV}"
        # Not ml_dtypes: this venv never sees the distro python's dist-packages (assemble-torch-app.sh builds it).
        apt-get install -y --no-install-recommends \
            python3-numpy python3-meson python3-ninja python3-cmake \
            python3-wheel python3-setuptools python3-packaging 2>/dev/null || true
        uv venv --seed --system-site-packages --python "/usr/local/bin/python${python_mm}" "${VIRTUAL_ENV}"
        # These fallbacks are the live values (nothing loads versions.env here); verify-arg-consistency keeps them equal.
        uv pip install --python "${VIRTUAL_ENV}/bin/python" "wheel==${PY_WHEEL_VERSION:-0.48.0}" "setuptools==${PY_SETUPTOOLS_VERSION:-84.0.0}" "cmake==${PY_CMAKE_VERSION:-4.4.4}" "packaging==${PY_PACKAGING_VERSION:-26.3}"
    else
        # numpy only here: riscv64 takes apt's python3-numpy.
        uv pip install --python "${VIRTUAL_ENV}/bin/python" "wheel==${PY_WHEEL_VERSION:-0.48.0}" "setuptools==${PY_SETUPTOOLS_VERSION:-84.0.0}" "numpy==${PY_NUMPY_VERSION:-2.5.2}" "meson==${PY_MESON_VERSION:-1.12.1}" "ninja==${PY_NINJA_VERSION:-1.13.0}" "cmake==${PY_CMAKE_VERSION:-4.4.4}" "packaging==${PY_PACKAGING_VERSION:-26.3}"
    fi
}

# Safety net for configure-runtime.sh's multiarch link, run before the dev surface is asserted.
repair_gstreamer_multiarch_link() {
    local prefix="${GSTREAMER_PREFIX:-/opt/gstreamer}" cand dir
    [ -e "${prefix}/lib/multiarch/pkgconfig/gstreamer-1.0.pc" ] && return 0
    for cand in "${prefix}"/lib/*/pkgconfig/gstreamer-1.0.pc \
                "${prefix}"/lib/pkgconfig/gstreamer-1.0.pc; do
        [ -f "${cand}" ] || continue
        dir="$(dirname "$(dirname "${cand}")")"
        ln -snf "${dir}" "${prefix}/lib/multiarch"
        echo "repaired ${prefix}/lib/multiarch -> ${dir} (cross meson libdir=lib; triplet dir was empty)"
        return 0
    done
    return 0   # nothing found — let verify_consumer_dev_surface fail loudly
}

# Fail here, not in a consumer's CI: at uid 1001 a consumer cannot apt-get the fix. GTK 4 dev is absent by design.
verify_consumer_dev_surface() {
    local missing=() mod
    # The source-built GStreamer, and openssl for openssl-sys.
    for mod in gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 openssl; do
        pkg-config --exists "${mod}" 2>/dev/null || missing+=("${mod}")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: the image's advertised dev surface is not reachable: ${missing[*]}" >&2
        echo "       PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-<unset>}" >&2
        echo "       GSTREAMER_PREFIX=${GSTREAMER_PREFIX:-<unset>}" >&2
        return 1
    fi
    echo "OK: dev surface reachable (gstreamer-1.0/-app/-video from ${GSTREAMER_PREFIX:-?}, openssl)"

    # CON19/CON20: optional per arch (append_available_packages), so a warning, not a gate.
    local tool absent=()
    for tool in perf jq Xvfb rg; do command -v "${tool}" >/dev/null 2>&1 || absent+=("${tool}"); done
    compgen -G '/usr/share/vulkan/icd.d/lvp_icd*.json' >/dev/null || absent+=("the lavapipe ICD")
    if [ "${#absent[@]}" -eq 0 ]; then
        echo "OK: perf, jq, Xvfb, rg and lavapipe (a CPU Vulkan device) are present"
    else
        echo "WARN: absent on this arch: ${absent[*]}"
    fi

    if pkg-config --exists gtk4 2>/dev/null; then
        echo "NOTE: gtk4 dev files are present. They are normally excluded on purpose;"
        echo "      if that was not deliberate, check whether the GLib/GIR dev chain"
        echo "      came along and broke a cross build's python3-minimal postinst."
    else
        echo "NOTE: no gtk4 dev files (expected). Consumers cannot build gui_unix /"
        echo "      gui_linux against this image; only gui_wgpu-style features work."
    fi
}

# Prints which Rust won, as rustup's and Ubuntu's can coexist; only the RUST_VERSION check is a gate.
report_rust_provenance() {
    echo "--- Rust provenance in the package image ---"
    local tool path
    for tool in cargo rustc rustup; do
        path="$(command -v "${tool}" 2>/dev/null || true)"
        if [ -z "${path}" ]; then
            printf '  %-7s NOT FOUND\n' "${tool}"
        else
            printf '  %-7s %s -> %s (%s)\n' "${tool}" "${path}" \
                "$(readlink -f "${path}" 2>/dev/null || echo '?')" \
                "$("${tool}" --version 2>/dev/null | head -1 || echo 'no --version')"
        fi
    done
    if ! command -v rustup >/dev/null 2>&1; then
        echo "  NOTE: no rustup. Consumers must call cargo directly; ANTfrastructure's" >&2
        echo "        own cargo_fmt_clippy.sh does 'rustup component add' and will" >&2
        echo "        exit 127 against this image." >&2
    fi
    echo "--------------------------------------------"

    # Hard gate: a shipped rustc off RUST_VERSION surfaces only as a consumer's dependency error.
    local want="${RUST_VERSION:-}" got
    if [ -z "${want}" ]; then
        echo "  NOTE: RUST_VERSION unset; cannot verify the toolchain matches its pin." >&2
        return 0
    fi
    got="$(rustc --version 2>&1 || true)"
    if [ "${got#rustc }" = "${got}" ] || [ "$(printf '%s' "${got}" | awk '{print $2}')" != "${want}" ]; then
        echo "ERROR: shipped rustc is not RUST_VERSION=${want}: ${got:-<no output>}" >&2
        echo "       Either ensure_native_rust_toolchain installed a different version, or apt's" >&2
        echo "       rustc shadows ${CARGO_HOME}/bin on PATH (see wire_cargo_symlinks)." >&2
        return 1
    fi
    echo "OK: shipped rustc ${got} matches the RUST_VERSION pin"
}

# See docs/artifact-copy-completeness.md § Bootstrapping Flutter in the package stage
bootstrap_flutter_sdk() {
    [ -x /opt/flutter/bin/flutter ] || return 0
    local arch out
    arch="$(dpkg --print-architecture)"
    git config --system --add safe.directory /opt/flutter
    if ! out="$(PATH="/opt/flutter/bin:${PATH}" flutter --suppress-analytics --version 2>&1)"; then
        printf '%s\n' "${out}" | tail -20 >&2
        echo "ERROR: flutter --version failed while bootstrapping the ${arch} Dart SDK; the shipped Flutter would be unusable" >&2
        return 1
    fi
    printf '%s\n' "${out}" | grep -m1 -E '^Flutter [0-9]'
    assert_elf_arch /opt/flutter/bin/cache/dart-sdk/bin/dart "${arch}"
    hand_root_created_paths_to_runtime_user /opt/flutter
    echo "OK: Flutter bootstrapped for ${arch}"
}

# The dated nightly, not the channel, whose update renames files out of a read-only layer. See docs/consumer-image-contract.md § The web-lane toolchain
install_web_lane_toolchain() {
    local rustup="${CARGO_HOME:?}/bin/rustup" cargo="${CARGO_HOME:?}/bin/cargo"
    local name version
    local nightly_toolchain="${RUST_NIGHTLY_TOOLCHAIN:-nightly-2026-06-28}"

    # The from-source leg; Dockerfile.package bind-mounts it for this RUN only.
    if ! declare -F wlt_install_from_source >/dev/null 2>&1; then
        # shellcheck source=linux/scripts/06-packaging/web-lane-tools.sh
        source /tmp/wlt/web-lane-tools.sh || { echo "ERROR: /tmp/wlt/web-lane-tools.sh is not mounted" >&2; return 1; }
    fi
    wlt_validate_knobs || return 1

    if [ ! -x "${rustup}" ] || [ ! -x "${cargo}" ]; then
        echo "WARN: no rustup/cargo under ${CARGO_HOME}; skipping the web-lane toolchain"
        return 0
    fi

    if "${rustup}" toolchain install "${nightly_toolchain}" --profile minimal \
         --component rust-src --target wasm32-unknown-unknown; then
        echo "OK: ${nightly_toolchain} installed with rust-src + wasm32-unknown-unknown"
    else
        echo "WARN: ${nightly_toolchain} is unavailable; the web lane will auto-install it per run"
    fi

    for name in "wasm-pack:${WASM_PACK_VERSION:-}" \
                "flutter_rust_bridge_codegen:${FLUTTER_RUST_BRIDGE_VERSION:-}"; do
        version="${name#*:}"
        name="${name%%:*}"
        [ -n "${version}" ] || { echo "WARN: no version pinned for ${name}; skipping"; continue; }
        if install_web_lane_prebuilt "${name}" "${version}"; then
            continue
        fi
        wlt_install_from_source "${name}" "${version}" || return 1
    done
}

# cargo-audit, cargo-deny and cargo-tarpaulin at their pins (CON65). See docs/consumer-image-contract.md § The cargo QA tools
install_cargo_qa_tools() {
    local name version

    case "$(uname -m)" in
        x86_64|aarch64) ;;
        *) echo "NOTE: no upstream cargo-audit/cargo-deny/cargo-tarpaulin binary for $(uname -m); not shipping them"; return 0 ;;
    esac
    for name in cargo-audit:CARGO_AUDIT_VERSION cargo-deny:CARGO_DENY_VERSION cargo-tarpaulin:CARGO_TARPAULIN_VERSION; do
        version="$(_versions_env_value "${name#*:}")"
        name="${name%%:*}"
        [ -n "${version}" ] || { echo "ERROR: no ${name} version in versions.env" >&2; return 1; }
        # No source fallback: a missing release binary would otherwise cost hundreds of crates under QEMU.
        install_web_lane_prebuilt "${name}" "${version}" \
            || { echo "ERROR: ${name} ${version} did not install from its pinned release binary" >&2; return 1; }
    done
}

# The free-threaded twin of PYTHON_VERSION for the 3.14t legs (CON66). See docs/consumer-image-contract.md § The free-threaded Python
install_free_threaded_python() {
    local root="${1:-/opt/python-freethreaded}" version exe mm report

    version="$(_versions_env_value PYTHON_VERSION)"
    [ -n "${version}" ] || { echo "ERROR: no PYTHON_VERSION in versions.env" >&2; return 1; }
    mm="${version%.*}"
    exe="${root}/bin/python${mm}t"
    # Dockerfile.package COPYs the toolchain's source build here; nothing downloads one in its place.
    if [ ! -x "${exe}" ]; then
        echo "ERROR: no ${exe}: the artifact's toolchain stage did not build the free-threaded CPython (build_python.sh)" >&2
        return 1
    fi
    ln -sf "${exe}" "/usr/local/bin/python${mm}t"
    # The modules the image smoke imports: a tree without one stops here, not in a consumer's leg.
    report="$("${exe}" -c 'import ssl, sqlite3, ctypes, zlib, lzma, bz2, sys; print(sys.version.split()[0], sys._is_gil_enabled())' 2>&1)" || true
    if [ "${report}" != "${version} False" ]; then
        echo "ERROR: python${mm}t reports '${report}', expected '${version} False'" >&2
        return 1
    fi
    echo "OK: free-threaded CPython ${version} at /usr/local/bin/python${mm}t"
}

# A versions.env value from the environment or the image's copy; the cargo QA pins are read, not forwarded.
_versions_env_value() {
    local key="$1"
    if [ -n "${!key:-}" ]; then
        printf '%s' "${!key}"
        return 0
    fi
    sed -n "s/^${key}=//p" "${VERSIONS_ENV:-/opt/scripts/core/versions.env}" 2>/dev/null | head -1
}

# Upstream's release asset for this machine, or empty when there is none (riscv64).
_web_lane_asset_url() {
    local name="$1" version="$2" target="$3"

    case "${name}" in
        wasm-pack)
            printf 'https://github.com/rustwasm/wasm-pack/releases/download/v%s/wasm-pack-v%s-%s.tar.gz' \
                "${version}" "${version}" "${target}" ;;
        flutter_rust_bridge_codegen)
            printf 'https://github.com/fzyzcjy/flutter_rust_bridge/releases/download/v%s/flutter_rust_bridge_codegen-%s-v%s.tgz' \
                "${version}" "${target}" "${version}" ;;
        cargo-audit)
            # Its aarch64 build is glibc, not musl.
            printf 'https://github.com/rustsec/rustsec/releases/download/cargo-audit%%2Fv%s/cargo-audit-%s-v%s.tgz' \
                "${version}" "${target/aarch64-unknown-linux-musl/aarch64-unknown-linux-gnu}" "${version}" ;;
        cargo-deny)
            printf 'https://github.com/EmbarkStudios/cargo-deny/releases/download/%s/cargo-deny-%s-%s.tar.gz' \
                "${version}" "${version}" "${target}" ;;
        cargo-tarpaulin)
            printf 'https://github.com/xd009642/tarpaulin/releases/download/%s/cargo-tarpaulin-%s.tar.gz' \
                "${version}" "${target}" ;;
    esac
}

# The asset's versions.env pin; without one the caller builds from source, which crates.io checksums.
_web_lane_asset_sha() {
    local key=""

    case "$1:$2" in
        wasm-pack:x86_64)                    key=WASM_PACK_LINUX_X86_64_SHA256 ;;
        wasm-pack:aarch64)                   key=WASM_PACK_LINUX_AARCH64_SHA256 ;;
        flutter_rust_bridge_codegen:x86_64)  key=FLUTTER_RUST_BRIDGE_LINUX_X86_64_SHA256 ;;
        flutter_rust_bridge_codegen:aarch64) key=FLUTTER_RUST_BRIDGE_LINUX_AARCH64_SHA256 ;;
        cargo-audit:x86_64)                  key=CARGO_AUDIT_LINUX_X86_64_SHA256 ;;
        cargo-audit:aarch64)                 key=CARGO_AUDIT_LINUX_AARCH64_SHA256 ;;
        cargo-deny:x86_64)                   key=CARGO_DENY_LINUX_X86_64_SHA256 ;;
        cargo-deny:aarch64)                  key=CARGO_DENY_LINUX_AARCH64_SHA256 ;;
        cargo-tarpaulin:x86_64)              key=CARGO_TARPAULIN_LINUX_X86_64_SHA256 ;;
        cargo-tarpaulin:aarch64)             key=CARGO_TARPAULIN_LINUX_AARCH64_SHA256 ;;
        *) return 0 ;;
    esac
    _versions_env_value "${key}"
}

# A verified download instead of ~200 crates under QEMU; non-zero means build from source.
install_web_lane_prebuilt() {
    local name="$1" version="$2"
    local machine target url sha tmp dir found

    machine="$(uname -m)"
    case "${machine}" in
        x86_64)  target="x86_64-unknown-linux-musl" ;;
        aarch64) target="aarch64-unknown-linux-musl" ;;
        *) echo "NOTE: no ${name} release binary for ${machine}; building it from source"; return 1 ;;
    esac

    url="$(_web_lane_asset_url "${name}" "${version}" "${target}")"
    sha="$(_web_lane_asset_sha "${name}" "${machine}")"
    [ -n "${url}" ] || return 1
    if [ -z "${sha}" ]; then
        echo "WARN: no SHA256 pinned for ${name}/${target}; refusing unverified bytes, building from source"
        return 1
    fi
    if ! declare -F download_verified_file >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        source /opt/scripts/core/downloads.sh 2>/dev/null || return 1
    fi

    dir="$(mktemp -d)" || return 1
    tmp="${dir}/asset"
    if ! download_verified_file "${url}" "${sha}" "${tmp}"; then
        echo "WARN: ${name} ${version} prebuilt did not download/verify; building from source"
        rm -rf "${dir}"; return 1
    fi
    # wasm-pack nests the binary in a versioned dir, frb does not.
    if ! tar -xzf "${tmp}" -C "${dir}"; then
        echo "WARN: ${name} ${version} prebuilt would not unpack; building from source"
        rm -rf "${dir}"; return 1
    fi
    found="$(find "${dir}" -type f -name "${name}" -perm -u+x -print -quit)"
    if [ -z "${found}" ] || ! install -m 0755 "${found}" "${CARGO_HOME:?}/bin/${name}"; then
        echo "WARN: ${name} ${version} prebuilt carried no ${name} binary; building from source"
        rm -rf "${dir}"; return 1
    fi
    rm -rf "${dir}"
    echo "OK: ${name} ${version} installed from the upstream ${target} release binary"
}

main() {
    local python_mm="${PYTHON_MAJOR_MINOR:?PYTHON_MAJOR_MINOR is required}"
    local gcc_major="${GCC_VERSION%%.*}"
    [ -n "${gcc_major}" ] || { echo "ERROR: GCC_VERSION is required" >&2; exit 1; }

    bash /opt/scripts/03-media/final/install-deps.sh
    apt-get update

    install_staged_target_python "${python_mm}"
    local -a _dev_packages=()
    select_dev_packages _dev_packages "${python_mm}" "${gcc_major}"
    install_dev_packages "${_dev_packages[@]}"
    drop_redundant_distro_gtk4
    anchor_java_home
    pin_clang_alternatives
    wire_python_symlinks "${python_mm}"
    preserve_custom_gcc "${GCC_VERSION}"
    wire_pinned_llvm_tools
    write_clang_gcc_toolchain_cfg
    link_compiler_rt_legacy_names
    ensure_native_rust_toolchain
    wire_cargo_symlinks
    install_web_lane_toolchain
    install_cargo_qa_tools
    install_free_threaded_python
    hand_root_created_paths_to_runtime_user "${RUSTUP_HOME:?}" "${CARGO_HOME:?}"
    create_runtime_venv "${python_mm}"

    add_prefix_python_paths_to_venv "/opt/opencv5" "${VIRTUAL_ENV}/bin/python"

    bash /opt/scripts/03-media/final/configure-runtime.sh
    ldconfig

    # Before the apt lists go, so apt-cache can still diagnose a failure on this layer.
    repair_gstreamer_multiarch_link
    verify_consumer_dev_surface
    report_rust_provenance
    bootstrap_flutter_sdk

    # Clean only committed dirs: the apt cache mounts never reach the layer and siblings reuse them.
    mountpoint -q /var/cache/apt || apt-get clean
    mountpoint -q /var/lib/apt   || rm -rf /var/lib/apt/lists/*
}

main "$@"
