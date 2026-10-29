#!/usr/bin/env bash
# riscv64 cross lanes: sysroot export, the cross env and the index lookup. See docs/riscv64-cross-test-lanes.md#the-pieces
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
HUB_ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)"

SYSROOT_SH="${SCRIPTS_DIR}/02-toolchain/riscv64-sysroot.sh"
DIGEST_PY="${SCRIPTS_DIR}/02-toolchain/registry-platform-digest.py"
LIB="${SCRIPTS_DIR}/lib/riscv64-cross.sh"
TOOLCHAIN="${HUB_ROOT}/cmake/toolchains/riscv64-linux-gnu.cmake"

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

t_case "absolute symlinks become relative and still name the same file"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_root="${_tmp}/sysroot"
mkdir -p "${_root}/usr/lib/riscv64-linux-gnu" "${_root}/etc/alternatives"
: > "${_root}/usr/lib/riscv64-linux-gnu/libblas.so.3"
ln -s /usr/lib/riscv64-linux-gnu/libblas.so.3 "${_root}/etc/alternatives/libblas.so.3"
ln -s libblas.so.3 "${_root}/usr/lib/riscv64-linux-gnu/libblas.so"
bash -c "source '${SYSROOT_SH}'; relativize_symlinks '${_root}'"
t_assert_eq "../../usr/lib/riscv64-linux-gnu/libblas.so.3" "$(readlink "${_root}/etc/alternatives/libblas.so.3")" \
  "an absolute target resolves against the build container's root, not the sysroot"
t_assert_eq "libblas.so.3" "$(readlink "${_root}/usr/lib/riscv64-linux-gnu/libblas.so")" "a relative link stays as it is"
t_assert_ok test -e "${_root}/etc/alternatives/libblas.so.3"

t_case "the allowlist carries the loader, the toolchain runtime and the loader cache"
_paths="$(bash -c "source '${SYSROOT_SH}'; printf '%s\n' \"\${RISCV64_SYSROOT_PATHS[@]}\"")"
for _p in usr/lib/ld-linux-riscv64-lp64d.so.1 opt/gcc-16.2.0 etc/ld.so.cache usr/lib/riscv64-linux-gnu lib; do
  t_assert_contains "${_paths}" "${_p}" "without ${_p} a riscv64 test binary does not load"
done

t_case "a pulled tag resolves to the digest it was pulled from"
_engine="${_tmp}/fake-engine"
printf '#!/bin/sh\nprintf "other/repo@sha256:aaa\\nghcr.io/k/img@sha256:bbb\\n"\n' > "${_engine}"
chmod +x "${_engine}"
t_assert_eq "ghcr.io/k/img@sha256:bbb" \
  "$(bash -c "source '${SYSROOT_SH}'; resolve_index_ref '${_engine}' ghcr.io/k/img:latest")" \
  "a later push to the tag must not pair a new riscv64 sysroot with the old amd64 image"
t_assert_eq "ghcr.io/k/img@sha256:ccc" \
  "$(bash -c "source '${SYSROOT_SH}'; resolve_index_ref '${_engine}' ghcr.io/k/img@sha256:ccc")" "a digest is taken as given"
printf '#!/bin/sh\nexit 1\n' > "${_engine}"
t_assert_eq "ghcr.io/k/img:latest" \
  "$(bash -c "source '${SYSROOT_SH}'; resolve_index_ref '${_engine}' ghcr.io/k/img:latest")" "an unpulled tag is looked up in the registry"

t_case "the index lookup takes exactly one manifest for the platform"
_probe() {
  python3 - "${DIGEST_PY}" "$@" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("rpd", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
idx = {"manifests": [
    {"digest": "sha256:amd", "platform": {"os": "linux", "architecture": "amd64"}},
    {"digest": "sha256:rv", "platform": {"os": "linux", "architecture": "riscv64"}},
    {"digest": "sha256:att", "platform": {"os": "unknown", "architecture": "unknown"}},
]}
try:
    print(m.select_platform(idx, sys.argv[2]))
except LookupError:
    print("LOOKUP")
print("/".join(m.split_ref(sys.argv[3])))
PY
}
_out="$(_probe linux/riscv64 ghcr.io/k/img@sha256:abc)"
t_assert_contains "${_out}" "sha256:rv" "the riscv64 child, not the first entry"
t_assert_contains "${_out}" "ghcr.io/k/img/sha256:abc" "a digest reference splits at @"
_out="$(_probe linux/arm64 ghcr.io/k/img:latest)"
t_assert_contains "${_out}" "LOOKUP" "a missing platform is an error, never a fallback to another arch"
t_assert_contains "${_out}" "ghcr.io/k/img/latest" "a tag reference splits at the last colon"

t_case "the newest LLVM with a riscv64 backend wins"
_llvm="${_tmp}/usr-lib"
for _v in 20 22 23; do
  mkdir -p "${_llvm}/llvm-${_v}/bin"
  _targets='    x86-64     - 64-bit X86'
  [ "${_v}" = 23 ] || _targets="${_targets}"$'\n''    riscv64    - 64-bit RISC-V'
  printf '#!/bin/sh\ncat <<EOF\n  Registered Targets:\n%s\nEOF\n' "${_targets}" > "${_llvm}/llvm-${_v}/bin/llc"
  chmod +x "${_llvm}/llvm-${_v}/bin/llc"
done
t_assert_eq "${_llvm}/llvm-22" "$(bash -c "source '${LIB}'; riscv64_cross_llvm_dir '${_llvm}'")" \
  "an X86-only LLVM (the image's own 23) must be skipped, not picked for being newest"
rm -rf "${_llvm}/llvm-20" "${_llvm}/llvm-22"
t_assert_fails bash -c "source '${LIB}'; riscv64_cross_llvm_dir '${_llvm}'"

t_case "the wrappers bake target, sysroot, GCC runtime and lld without unused-argument noise"
bash -c "source '${LIB}'; riscv64_cross_write_wrappers '${_tmp}/bin' /usr/lib/llvm-22 /opt/rv"
_w="$(cat "${_tmp}/bin/riscv64-linux-gnu-clang++")"
t_assert_contains "${_w}" 'exec "/usr/lib/llvm-22/bin/clang++"' "the C++ wrapper must run the C++ driver"
t_assert_contains "${_w}" "--target=riscv64-linux-gnu" "a wrapper without the triple is the host compiler"
t_assert_contains "${_w}" "--sysroot=/opt/rv" "the riscv64 image's headers and libraries"
t_assert_contains "${_w}" "--gcc-toolchain=/opt/rv/opt/gcc-16.2.0" "the libstdc++ the image's riscv64 libraries link"
t_assert_contains "${_w}" "-L/opt/rv/opt/gcc-16.2.0/lib" "clang does not search a cross GCC's lib/ for libstdc++"
t_assert_contains "${_w}" "-march=rv64gcv_zicsr_zifencei_zba_zbb_zbs_zicond" "the image's riscv64 baseline"
t_assert_contains "${_w}" "--start-no-unused-arguments -fuse-ld=lld" \
  "link flags on a compile line warn, and -Werror builds turn that into a failure"
t_assert_ok test -x "${_tmp}/bin/riscv64-linux-gnu-clang"
t_assert_fails bash -c "source '${LIB}'; riscv64_cross_write_wrappers '${_tmp}/b b' /usr/lib/llvm-22 /opt/rv"

t_case "pkg-config sees only riscv64 directories"
_pc="$(bash -c "source '${LIB}'; riscv64_cross_pkg_config_libdir /opt/rv")"
t_assert_contains "${_pc}" "/opt/rv/opt/gstreamer/lib/pkgconfig" "the image's own GStreamer"
t_assert_contains "${_pc}" "/opt/rv/usr/lib/riscv64-linux-gnu/pkgconfig" "the distro's multiarch .pc files"
t_assert_eq "" "$(printf '%s' "${_pc}" | tr ':' '\n' | grep -v -e '^/opt/rv/' || true)" "every entry is inside the sysroot"

t_case "host-triplet dirs under /opt leave a runtime list; riscv64, multiarch and distro dirs stay"
_strip() { bash -c "source '${LIB}'; riscv64_cross_strip_host_dirs \"\$1\"" _ "$1"; }
t_assert_eq "/opt/gstreamer/lib/gstreamer-1.0:/opt/gstreamer/lib/multiarch/gstreamer-1.0:/opt/libcamera/lib/gstreamer-1.0" \
  "$(_strip /opt/gstreamer/lib/x86_64-linux-gnu/gstreamer-1.0:/opt/gstreamer/lib/gstreamer-1.0:/opt/gstreamer/lib/multiarch/gstreamer-1.0:/opt/libcamera/lib/gstreamer-1.0)" \
  "the amd64 plugin dir is dropped, order kept"
t_assert_eq "/opt/gstreamer/lib/riscv64-linux-gnu:/usr/lib/x86_64-linux-gnu" \
  "$(_strip /opt/gstreamer/lib/aarch64-linux-gnu:/opt/gstreamer/lib/riscv64-linux-gnu:/usr/lib/x86_64-linux-gnu)" \
  "an arm64 host dir goes too; riscv64 and distro dirs stay"
t_assert_eq "" "$(_strip "")" "an empty list stays empty"

t_case "cross environment hides amd64 pkg-config metadata from Rust and direct probes"
_cross_sysroot="${_tmp}/cross-pc/sysroot"
_cross_llvm="${_tmp}/cross-pc/llvm"
mkdir -p "${_cross_sysroot}/lib" "${_cross_llvm}/bin"
printf '#!/bin/sh\nexit 0\n' > "${_cross_sysroot}/lib/ld-linux-riscv64-lp64d.so.1"
chmod +x "${_cross_sysroot}/lib/ld-linux-riscv64-lp64d.so.1"
printf '#!/bin/sh\nprintf "clang version 22\\n"\n' > "${_cross_llvm}/bin/clang"
chmod +x "${_cross_llvm}/bin/clang"
_cross_libdir="$(bash -c "source '${LIB}'; riscv64_cross_pkg_config_libdir '${_cross_sysroot}'")"
# shellcheck disable=SC2016
_cross_env="$(env RISCV64_SYSROOT="${_cross_sysroot}" \
  PKG_CONFIG_PATH=/opt/gstreamer/lib/x86_64-linux-gnu/pkgconfig \
  PKG_CONFIG_PATH_riscv64gc_unknown_linux_gnu=/opt/gstreamer/lib/x86_64-linux-gnu/pkgconfig \
  PKG_CONFIG_LIBDIR=/usr/lib/x86_64-linux-gnu/pkgconfig PKG_CONFIG_SYSROOT_DIR=/ \
  GST_PLUGIN_PATH=/opt/gstreamer/lib/x86_64-linux-gnu/gstreamer-1.0:/opt/gstreamer/lib/multiarch/gstreamer-1.0 \
  GI_TYPELIB_PATH=/opt/gstreamer/lib/x86_64-linux-gnu/girepository-1.0 \
  LD_LIBRARY_PATH=/opt/gstreamer/lib/x86_64-linux-gnu:/opt/gstreamer/lib/multiarch \
  bash -c '
    source "$1"
    _fake_llvm="$3"
    riscv64_cross_llvm_dir() { printf "%s" "${_fake_llvm}"; }
    riscv64_cross_env "$2" || exit
    printf "path=%s\n" "${PKG_CONFIG_PATH+present}"
    printf "target-path=%s\n" "${PKG_CONFIG_PATH_riscv64gc_unknown_linux_gnu+present}"
    printf "libdir=%s\n" "${PKG_CONFIG_LIBDIR}"
    printf "sysroot=%s\n" "${PKG_CONFIG_SYSROOT_DIR}"
    printf "target-libdir=%s\n" "${PKG_CONFIG_LIBDIR_riscv64gc_unknown_linux_gnu}"
    printf "plugins=%s\n" "${GST_PLUGIN_PATH}"
    printf "typelibs=%s\n" "${GI_TYPELIB_PATH}"
    printf "libs=%s\n" "${LD_LIBRARY_PATH}"
  ' _ "${LIB}" "${_tmp}/cross-pc/bin" "${_cross_llvm}")"; _rc=$?
t_assert_eq 0 "${_rc}" "the fixture must reach the exported environment"
t_assert_contains "${_cross_env}" 'path=' "host PKG_CONFIG_PATH must not outrank the target library directory"
t_assert_eq "" "$(printf '%s\n' "${_cross_env}" | grep -Fx 'path=present' || true)" \
  "the image's native GStreamer .pc files must be hidden"
t_assert_eq "" "$(printf '%s\n' "${_cross_env}" | grep -Fx 'target-path=present' || true)" \
  "an inherited Rust target path must not reintroduce host metadata"
t_assert_contains "${_cross_env}" "libdir=${_cross_libdir}" \
  "direct pkg-config probes must search the target sysroot"
t_assert_contains "${_cross_env}" "sysroot=${_cross_sysroot}" \
  "direct pkg-config probes must rewrite target paths into the sysroot"
t_assert_contains "${_cross_env}" "target-libdir=${_cross_libdir}" \
  "pkg-config-rs must receive the same target directory"
t_assert_contains "${_cross_env}" "plugins=/opt/gstreamer/lib/multiarch/gstreamer-1.0" \
  "QEMU must not reach the amd64 plugins through GST_PLUGIN_PATH"
t_assert_contains "${_cross_env}" "typelibs=" "an all-host GI_TYPELIB_PATH is emptied"
t_assert_eq "" "$(printf '%s\n' "${_cross_env}" | grep -e '^typelibs=.' || true)" "no amd64 typelib dir survives"
t_assert_contains "${_cross_env}" "libs=/opt/gstreamer/lib/multiarch" "the loader keeps the arch-neutral dir only"

t_case "riscv64_cross_env refuses a missing sysroot instead of building for the host"
_out="$(RISCV64_SYSROOT="${_tmp}/none" bash -c "source '${LIB}'; riscv64_cross_env '${_tmp}/bin2'" 2>&1)"; _rc=$?
t_assert_eq 1 "${_rc}" "no sysroot must stop the lane"
t_assert_contains "${_out}" "riscv64-sysroot.sh" "the error names the tool that builds one"

t_case "the CMake toolchain uses the wrappers, the riscv64 scan-deps and a sysroot-only search"
_tc="$(cat "${TOOLCHAIN}")"
t_assert_contains "${_tc}" 'riscv64-linux-gnu-clang++"' "CMake must drive the cross wrapper"
# shellcheck disable=SC2016
t_assert_contains "${_tc}" '"$ENV{RISCV64_CROSS_LLVM}/bin/clang-scan-deps"' \
  "the image's own scan-deps has no riscv64 backend, so module scanning would fail"
t_assert_contains "${_tc}" "CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY" "an amd64 library must never satisfy a riscv64 link"
t_assert_contains "${_tc}" "set(CMAKE_CROSSCOMPILING_EMULATOR" "try_run and test discovery need permission to execute"
if command -v cmake >/dev/null 2>&1; then
  _out="$(env -u RISCV64_SYSROOT cmake -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" -P "${TOOLCHAIN}" 2>&1)"
  t_assert_contains "${_out}" "riscv64_cross_env" "an unprepared shell fails with the fix, not a host build"
fi


t_case "without --image the sysroot script resolves the family image and reaches the engine check"
_out="$(bash "${SYSROOT_SH}" --dest "${_tmp}/no-image" --engine "${_tmp}/no-such-engine" 2>&1)"
t_assert_contains "${_out}" "container engine not found" "the default image resolved, so the run got as far as the engine"
t_assert_eq "" "$(printf '%s' "${_out}" | grep 'unknown argument' || true)" "ci-image-ref.sh takes --linux, not linux"
t_summary
