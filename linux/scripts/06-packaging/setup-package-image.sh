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
        uv pip install --python "${VIRTUAL_ENV}/bin/python" "wheel==${PY_WHEEL_VERSION:-0.47.0}" "setuptools==${PY_SETUPTOOLS_VERSION:-83.0.0}" cmake packaging
    else
        uv pip install --python "${VIRTUAL_ENV}/bin/python" "wheel==${PY_WHEEL_VERSION:-0.47.0}" "setuptools==${PY_SETUPTOOLS_VERSION:-83.0.0}" numpy "meson==${PY_MESON_VERSION:-1.11.2}" "ninja==${PY_NINJA_VERSION:-1.13.0}" cmake packaging
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
    got="$(rustc --version 2>/dev/null | awk '{print $2}')"
    if [ "${got}" != "${want}" ]; then
        echo "ERROR: shipped rustc is ${got:-<none>}, but versions.env pins RUST_VERSION=${want}." >&2
        echo "       The pinned toolchain lives in /usr/local/{cargo,rustup} and must be" >&2
        echo "       COPY'd into this stage; check those COPY lines in Dockerfile.package." >&2
        echo "       Without them the ENV points at empty paths and wire_cargo_symlinks" >&2
        echo "       falls back to the apt cargo/rustc debs." >&2
        return 1
    fi
    echo "OK: shipped rustc ${got} matches the RUST_VERSION pin"
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
    pin_clang_alternatives
    wire_python_symlinks "${python_mm}"
    preserve_custom_gcc "${GCC_VERSION}"
    wire_cargo_symlinks
    create_runtime_venv "${python_mm}"

    add_prefix_python_paths_to_venv "/opt/opencv5" "${VIRTUAL_ENV}/bin/python"

    bash /opt/scripts/03-media/final/configure-runtime.sh
    ldconfig

    # Verify BEFORE the apt lists are wiped, so a failure can still be
    # diagnosed with apt-cache inside a `docker run` on the failed layer.
    repair_gstreamer_multiarch_link
    verify_consumer_dev_surface
    report_rust_provenance

    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

main "$@"
