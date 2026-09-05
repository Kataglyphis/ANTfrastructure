#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /opt/scripts/core/platform.sh
# A set -e death in these image-side scripts printed nothing at all until
# 2026-09-03. docs/failure-modes.md#a-packaging-script-dies-with-no-message
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
            elif [ -e "${staged_python_root}" ]; then
                # Staged tree present but unusable: never fall through to the distro python.
                echo "ERROR: ${staged_python_root} exists but carries no executable usr/local/bin/python${python_mm}" >&2
                return 1
            else
                # Expected: Dockerfile.package stages no /opt/python-cross, so the
                # distro python is used and PYTHON_VERSION is not advertised.
                echo "No staged target Python at ${staged_python_root}; using the distro python${python_mm}."
            fi
            ;;
    esac
}

# Choose the dev/runtime apt packages (python-dev, matching gcc/g++, llvm/clang
# extras) based on what's available, then install them.
# (Complexity audit F-G: this function used to weld two unrelated jobs —
# package selection/install AND clang toolchain pinning — into 102 lines with
# a nested function leaking globally. Split into select_dev_packages /
# install_dev_packages / clang_embedded_deb_version / pin_clang_alternatives;
# the wrapper keeps the old name for its single caller.)
select_dev_packages() {
    local -n _sdp_out=$1
    local python_mm="$2" gcc_major="$3"
    # NOTE: `cargo`/`rustc` here are Ubuntu's debs, and the deb set ships NO
    # rustup. That matters because wire_cargo_symlinks() below links whatever
    # `command -v` happens to find into ${CARGO_HOME}/bin — so when this stage's
    # base has no rustup-installed toolchain, `cargo` silently resolves to
    # /usr/bin/cargo and `rustup` resolves to nothing at all. A consumer then
    # sees the confusing pair "cargo works, rustup: command not found"
    # (Kataglyphis-RustProjectTemplate, 2026-08-07). report_rust_provenance()
    # at the end of main() now prints which one actually won.
    # (Nothing is added to this list here - see the note below the
    # append_available_packages call about gstreamer/gtk4 dev packages.)
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

    # LLVM apt packages. The major MUST track LLVM_RELEASE, because
    # pin_clang_alternatives below looks for /usr/lib/llvm-${LLVM_RELEASE%%.*}
    # -- a hard-coded major here would install llvm-22 while that search asks
    # for llvm-23, and the apt candidate could then never win.
    # append_available_packages SKIPS packages apt does not have, which is the
    # trap: on a distro that has not published the new major yet, asking only
    # for it installs NOTHING and silently drops the libLLVM/libclang dev libs
    # this stage needs. So ask for the wanted major AND keep 22 as a floor --
    # whichever exists is taken, and having both is harmless.
    local _pkg_llvm_major
    _pkg_llvm_major="${LLVM_RELEASE%%.*}"
    [ -n "${_pkg_llvm_major}" ] || _pkg_llvm_major=22
    append_available_packages _sdp_out \
        "clang-${_pkg_llvm_major}" "lld-${_pkg_llvm_major}" \
        "llvm-${_pkg_llvm_major}" "llvm-${_pkg_llvm_major}-dev" \
        "libclang-rt-${_pkg_llvm_major}-dev" "libfuzzer-${_pkg_llvm_major}-dev"
    append_available_packages _sdp_out clang-22 lld-22 llvm-22 llvm-22-dev \
        libclang-rt-22-dev libfuzzer-22-dev cargo-c

    # DO NOT add libgstreamer*-dev or libgtk-4-dev here. Both look like the
    # obvious fix for a consumer whose `--features gstreamer` / `gui_linux`
    # build cannot find headers, and both are wrong:
    #   * GStreamer is SOURCE-BUILT into ${GSTREAMER_PREFIX} and its .pc files
    #     are already on PKG_CONFIG_PATH. 03-media/runtime/install-deps.sh
    #     deliberately `apt-get purge`s every distro gstreamer package; adding
    #     the -dev deb back reintroduces exactly what that purge removes.
    #   * libgtk-4-dev is excluded on purpose - see the comment above that same
    #     purge: the foreign-arch GTK dev package drags in the GLib/GIR dev
    #     chain, which pulls target-side Python and breaks cross builds on
    #     python3-minimal's postinst.
    # libssl-dev already arrives via package-lists.sh.

    # Gradle refuses to run without a JDK, and the SDK COPY leaves the source
    # stage's one behind (it went to /usr/lib/jvm via apt, not /opt/android-sdk).
    # Asked for by name, not through append_available_packages: a silently
    # skipped JDK ships an Android SDK that cannot build anything.
    _sdp_out+=("${JDK_PACKAGE:?JDK_PACKAGE is required (01-core/versions.env)}")
}

# JAVA_HOME must survive a JDK bump, and Ubuntu's real path carries both the
# version and the arch (java-21-openjdk-riscv64). Resolve it once from the
# installed javac and park a stable symlink the image ENV can point at.
# docs/consumer-image-contract.md#the-android-lane-needs-a-jdk
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

# Read a clang binary's version from its embedded DEB metadata, --version
# fallback. (Bundled sibling of validate-compilers.sh's _vc_clang_embedded_version.)
clang_embedded_deb_version() {
    local _bin="$1" _ver=""
    # The binary's --version reports the RUNTIME libclang-cpp version, not
    # the binary's own built-in version. The apt clang-<major> package ships
    # libclang-cpp.so at /usr/lib which shadows the source-built lib at the
    # toolchain's own lib/ dir.  Read the version from the binary's embedded
    # DEB package metadata instead — it reflects the source-built version.
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
#
# NEVER overwrite what rustup already put there. link_command_if_present resolves
# via `command -v`, i.e. through PATH - and in the built image PATH carries /bin
# and /usr/local/bin AHEAD of /usr/local/cargo/bin:
#
#   PATH=/opt/venv/bin:...:/bin:/bin:/usr/local/bin:...:/usr/local/cargo/bin:...
#
# so `command -v rustc` finds Ubuntu's apt rustc and `ln -sf` then replaces the
# rustup shim with it. The pinned toolchain is present and correct in the image -
# Dockerfile.package COPYs /usr/local/{rustup,cargo} from the toolchain stage -
# and this function quietly demoted it afterwards.
#
# Measured 2026-08-12: the image carried RUST_VERSION=1.97.1 as pinned, yet
# consumers ran rustc 1.93.1 and Kataglyphis-RustProjectTemplate died on
# "rustc 1.93.1 is not supported by ... sysinfo@0.39.6 requires rustc 1.95".
#
# The fallback these links exist for - an image with NO rustup at all - still
# works: nothing is at the link path then, so the apt binary is linked as before.
_link_unless_rustup_provides() {
    local command_name="$1" link_path="$2"

    if [ -e "${link_path}" ] || [ -L "${link_path}" ]; then
        echo "Keeping existing ${link_path} (rustup toolchain wins over PATH lookup)"
        return 0
    fi
    link_command_if_present "${command_name}" "${link_path}"
}

# The artifact image is an amd64 host, so the COPY'd /usr/local/{rustup,cargo}
# is x86_64 on every foreign arch: 2 GB that cannot execute, shipped that way in
# every arm64/riscv64 image until 2026-09-03. Replace it with a native install
# when no toolchain for this image's own triple is present (amd64 is a no-op).
# docs/failure-modes.md#the-copied-rust-toolchain-is-the-builders-arch
ensure_native_rust_toolchain() {
    local triple
    triple="$(rust_target_triple_for_arch "$(dpkg --print-architecture)")" || return 0
    if compgen -G "${RUSTUP_HOME}/toolchains/*-${triple}" >/dev/null; then
        echo "Rust toolchain in ${RUSTUP_HOME} is native (${triple})"
        return 0
    fi
    echo "Rust toolchain in ${RUSTUP_HOME} is not ${triple}: $(ls "${RUSTUP_HOME}/toolchains" 2>/dev/null | tr '\n' ' ')-- reinstalling natively"
    rm -rf "${RUSTUP_HOME}" "${CARGO_HOME}"
    RUST_INSTALL_CARGO_C=0 BUILD_MODE=native bash /opt/scripts/toolchain/install-rust.sh
}

# Hand the paths root wrote in THIS RUN to the runtime user. Only what root
# still owns is chowned: a blanket chown -R rewrites metadata on a tree that
# entered the stage via COPY --chown and copies it up into this layer (rustup
# 2.0 GB + cargo 173 MB, /opt/flutter 716 MB). Modes are untouched, so a tree
# stays owner-writable, never world-writable.
# docs/artifact-copy-completeness.md#the-rust-toolchain-must-be-writable-by-the-runtime-user
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

    # Fail the BUILD rather than ship a silently downgraded toolchain. A version
    # skew here does not surface in the image - it surfaces days later in a
    # consumer, as an MSRV error on some dependency, pointing at the dependency
    # instead of at us.
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
        # Executor pins per supply-chain audit #18; the :- fallbacks below ARE
        # the live values (this script sources platform.sh/package-lists.sh
        # only, not common.sh, so nothing loads the baked versions.env into
        # its env) and must stay equal to versions.env's PY_* keys —
        # verify-arg-consistency's drift check compares them. 2026-08-24:
        # fallbacks re-synced (wheel
        # 0.47.0->0.48.0, setuptools 83->84, meson 1.11.2->1.12.0) and the
        # last three BARE installs pinned (cmake/packaging here, +numpy below;
        # pip cmake 4.4.2 ships a riscv64 manylinux wheel, packaging is a
        # pure-python `any` wheel — both safe on this QEMU branch).
        uv pip install --python "${VIRTUAL_ENV}/bin/python" "wheel==${PY_WHEEL_VERSION:-0.48.0}" "setuptools==${PY_SETUPTOOLS_VERSION:-84.0.0}" "cmake==${PY_CMAKE_VERSION:-4.4.2}" "packaging==${PY_PACKAGING_VERSION:-26.3}"
    else
        # numpy pinned here only (riscv64 gets apt python3-numpy above);
        # 2.5.2 ships cp314 manylinux wheels for x86_64 and aarch64.
        uv pip install --python "${VIRTUAL_ENV}/bin/python" "wheel==${PY_WHEEL_VERSION:-0.48.0}" "setuptools==${PY_SETUPTOOLS_VERSION:-84.0.0}" "numpy==${PY_NUMPY_VERSION:-2.5.2}" "meson==${PY_MESON_VERSION:-1.12.0}" "ninja==${PY_NINJA_VERSION:-1.13.0}" "cmake==${PY_CMAKE_VERSION:-4.4.2}" "packaging==${PY_PACKAGING_VERSION:-26.3}"
    fi
}

# Assert that the DEV surface this image intends to expose is actually
# reachable through pkg-config, and fail the build here rather than in a
# consumer's CI hours later. A consumer cannot repair any of this itself: the
# runtime container runs as uid 1001, where `apt-get` dies with
# "Permission denied".
#
# Only things the image genuinely promises are checked. GTK4 dev is absent BY
# DESIGN (see select_dev_packages), so it is reported, not enforced
# - asserting it would turn a deliberate policy into a build failure.
# Repair the gstreamer multiarch symlink BEFORE asserting the dev surface
# (2026-08-11, first cross-arch run of the Klasse-B gate): NATIVE meson
# installs to lib/<triplet>/ (Debian default) but the CROSS builds pass
# libdir=lib (cargo_wrapper invocation in the media logs proves it), so on
# arm64/riscv64 configure-runtime's `multiarch -> lib/<triplet>` symlink
# points at an EMPTY directory while the real .pc files sit in lib/pkgconfig.
# The July images shipped this dangling dev surface silently — the new gate
# is the first thing to look. Point multiarch at whichever directory actually
# carries gstreamer-1.0.pc. ROOT fix (make configure-runtime resolve the real
# libdir, or force cross meson to lib/<triplet>) is backlogged for the media
# closure window — this keeps the package lane honest either way.
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

verify_consumer_dev_surface() {
    local missing=() mod
    # gstreamer-*: the SOURCE-built stack under ${GSTREAMER_PREFIX}. If these
    # stop resolving, either the prefix moved or PKG_CONFIG_PATH regressed -
    # both silently break every consumer's `--features gstreamer`.
    # openssl: openssl-sys (ort, and anything reqwest-shaped) needs it.
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

    if pkg-config --exists gtk4 2>/dev/null; then
        echo "NOTE: gtk4 dev files are present. They are normally excluded on purpose;"
        echo "      if that was not deliberate, check whether the GLib/GIR dev chain"
        echo "      came along and broke a cross build's python3-minimal postinst."
    else
        echo "NOTE: no gtk4 dev files (expected). Consumers cannot build gui_unix /"
        echo "      gui_linux against this image; only gui_wgpu-style features work."
    fi
}

# Diagnostic, deliberately non-fatal: print WHICH Rust the image ended up with.
# Two can coexist — the pinned rustup toolchain under ${CARGO_HOME} and Ubuntu's
# cargo/rustc debs — and the loser is invisible until a consumer's build picks
# the wrong one. Not a hard gate, because whether rustup belongs in this image
# is a policy call, not a build error.
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
        echo "  NOTE: no rustup. Consumers must call cargo directly; ContainerHub's" >&2
        echo "        own cargo_fmt_clippy.sh does 'rustup component add' and will" >&2
        echo "        exit 127 against this image." >&2
    fi
    echo "--------------------------------------------"

    # HARD GATE. The image previously shipped Ubuntu's rustc while versions.env
    # pinned a much newer one, because Dockerfile.package declared CARGO_HOME /
    # RUSTUP_HOME / PATH for a toolchain it never COPY'd in. Nothing failed at
    # build time; it surfaced only when a consumer's dependency demanded a
    # newer rustc than the image happened to have, in a message that blamed
    # the dependency. Never again silently: if the shipped rustc does not match
    # RUST_VERSION, the image is wrong and this build stops.
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

# The sdk stage ships Flutter bare (empty bin/cache): the Dart SDK and the
# flutter_tools snapshot are per-arch and only this target-arch stage can create
# them. Runs as root, so EVERY path root leaves behind -- bin/cache, the fetched
# git objects, flutter_tools/.dart_tool -- goes through the same handover the rust
# trees use; the rest of the tree is the COPY --chown's and must not be rewritten.
# docs/artifact-copy-completeness.md#bootstrapping-flutter-in-the-package-stage
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

# The web lane, measured in a consumer run: two `cargo install` from source per
# invocation (wasm-pack 258 crates, flutter_rust_bridge_codegen 174), plus a
# nightly rustup auto-install through a path rustup itself calls deprecated.
# The dated pin install-rust.sh adds is not enough -- `wasm-pack -Z build-std`
# invokes `cargo +nightly`, which resolves the CHANNEL name, not the pin.
# Non-fatal throughout: a consumer that has to build its own tools is slow, one
# that cannot build the image at all is worse.
# docs/consumer-image-contract.md#the-web-lane-toolchain
install_web_lane_toolchain() {
    local rustup="${CARGO_HOME:?}/bin/rustup" cargo="${CARGO_HOME:?}/bin/cargo"
    local name version

    if [ ! -x "${rustup}" ] || [ ! -x "${cargo}" ]; then
        echo "WARN: no rustup/cargo under ${CARGO_HOME}; skipping the web-lane toolchain"
        return 0
    fi

    if "${rustup}" toolchain install nightly --profile minimal \
         --component rust-src --target wasm32-unknown-unknown; then
        echo "OK: nightly channel installed with rust-src + wasm32-unknown-unknown"
    else
        echo "WARN: the nightly channel is unavailable; the web lane will auto-install it per run"
    fi

    for name in "wasm-pack:${WASM_PACK_VERSION:-}" \
                "flutter_rust_bridge_codegen:${FLUTTER_RUST_BRIDGE_VERSION:-}"; do
        version="${name#*:}"
        name="${name%%:*}"
        [ -n "${version}" ] || { echo "WARN: no version pinned for ${name}; skipping"; continue; }
        if "${cargo}" install --locked "${name}" --version "${version}"; then
            echo "OK: ${name} ${version} installed"
        else
            echo "WARN: cargo install ${name} ${version} failed; the web lane will build it per run"
        fi
    done
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
    anchor_java_home
    pin_clang_alternatives
    wire_python_symlinks "${python_mm}"
    preserve_custom_gcc "${GCC_VERSION}"
    ensure_native_rust_toolchain
    wire_cargo_symlinks
    install_web_lane_toolchain
    hand_root_created_paths_to_runtime_user "${RUSTUP_HOME:?}" "${CARGO_HOME:?}"
    create_runtime_venv "${python_mm}"

    add_prefix_python_paths_to_venv "/opt/opencv5" "${VIRTUAL_ENV}/bin/python"

    bash /opt/scripts/03-media/final/configure-runtime.sh
    ldconfig

    # Verify BEFORE the apt lists are wiped, so a failure can still be
    # diagnosed with apt-cache inside a `docker run` on the failed layer.
    repair_gstreamer_multiarch_link
    verify_consumer_dev_surface
    report_rust_provenance
    bootstrap_flutter_sdk

    # RP2: /var/cache/apt and /var/lib/apt are BuildKit cache MOUNTS here
    # (Dockerfile.package:307-308, sharing=locked). Wiping them has ZERO
    # image-size benefit (a mount never commits to the layer) and forces sibling
    # arches to re-download all apt metadata on their next run. Only clean a real
    # committed dir. `mountpoint` missing → falls back to the old wipe (safe).
    mountpoint -q /var/cache/apt || apt-get clean
    mountpoint -q /var/lib/apt   || rm -rf /var/lib/apt/lists/*
}

main "$@"
