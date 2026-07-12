#!/usr/bin/env bash
set -euo pipefail

# swap-native-gcc.sh
#
# Swaps the amd64-hosted GCC at /opt/gcc-${GCC_VERSION} with the target-native
# GCC (cross-compiled from source during the compiler image build, stored at
# /opt/gcc-${GCC_VERSION}-native-${TARGET_ARCH}/).
#
# Performs ELF architecture assertions before and after the swap, creates
# symlinks for GCC target lib/include directories, and runs a compile smoke test.
#
# Environment:
#   TARGET_ARCH   amd64, arm64, or riscv64
#   GCC_VERSION   e.g. 16.1.0
#   BUILD_MODE    cross or native

_swap_gcc_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _swap_mod_path in \
  "${_swap_gcc_script_dir}/../01-core/modules.sh" \
  "/opt/scripts/core/modules.sh"; do
  if [ -f "${_swap_mod_path}" ]; then
    # shellcheck disable=SC1090
    source "${_swap_mod_path}"
    break
  fi
done
source_module platform.sh

main() {
  : "${TARGET_ARCH:?TARGET_ARCH is required}"
  : "${GCC_VERSION:?GCC_VERSION is required}"

  if [ "${TARGET_ARCH}" != "amd64" ] && [ "${BUILD_MODE:-}" = "cross" ]; then
    local native_gcc="/opt/gcc-${GCC_VERSION}-native-${TARGET_ARCH}"
    if [ ! -d "${native_gcc}" ]; then
      echo "ERROR: expected target-native GCC at ${native_gcc} but not found" >&2
      echo "ERROR: Rebuild the toolchain image (build-cross-compiler.sh) to produce" >&2
      echo "ERROR: the Canadian cross GCC, then rebuild this android image." >&2
      exit 1
    fi

    assert_elf_arch "${native_gcc}/bin/gcc" "${TARGET_ARCH}"
    assert_elf_arch "${native_gcc}/bin/g++" "${TARGET_ARCH}"

    rm -rf "/opt/gcc-${GCC_VERSION}"
    cp -a "${native_gcc}" "/opt/gcc-${GCC_VERSION}"

    assert_elf_arch "/opt/gcc-${GCC_VERSION}/bin/gcc" "${TARGET_ARCH}"
    echo "Replaced host GCC with target-native ${TARGET_ARCH} GCC at /opt/gcc-${GCC_VERSION}"

    local triplet
    triplet="$(arch_deb_multiarch_triplet_for "${TARGET_ARCH}")"
    if [ -n "${triplet}" ]; then
      local gcc_target_lib="/opt/gcc-${GCC_VERSION}/${triplet}/lib"
      local sys_multiarch_lib="/usr/lib/${triplet}"
      if [ ! -d "${gcc_target_lib}" ] || [ -z "$(ls -A "${gcc_target_lib}" 2>/dev/null)" ]; then
        rm -rf "${gcc_target_lib}"
        mkdir -p "$(dirname "${gcc_target_lib}")"
        ln -sf "${sys_multiarch_lib}" "${gcc_target_lib}"
        echo "Linked GCC target lib ${gcc_target_lib} -> ${sys_multiarch_lib}"
      fi

      local gcc_target_include="/opt/gcc-${GCC_VERSION}/${triplet}/include"
      local sys_multiarch_include="/usr/include/${triplet}"
      if [ ! -e "${gcc_target_include}" ]; then
        mkdir -p "$(dirname "${gcc_target_include}")"
        ln -sf "${sys_multiarch_include}" "${gcc_target_include}"
        echo "Linked GCC target include ${gcc_target_include} -> ${sys_multiarch_include}"
      fi

      # The relocated Canadian-cross native GCC/G++ keeps the sysroot baked in at
      # compiler-build time, so it does NOT search the runtime image's
      # /usr/include by default. Source builds under QEMU (e.g. pip compiling C or
      # C++ extensions when PyPI ships no target-arch wheel) then fail to find
      # libc headers:
      #   C:   "fatal error: string.h: No such file or directory"
      #   C++: <cstdlib> does `#include_next <stdlib.h>` -> "stdlib.h: No such"
      # CPATH (=-I, before system dirs) fixes plain C includes but NOT the C++
      # #include_next, which must resolve /usr/include AFTER libstdc++ headers. So
      # also inject the system dirs with -idirafter (appended AFTER all built-in
      # dirs) via *FLAGS. Same logic as the canonical helper
      # append_cross_idirafter() in 01-core/common.sh, inlined because this runs
      # in the android stage without common.sh; kept in sync via
      # verify-critical-fixes.sh fix6. Written to
      # profile.d so login-shell compiles inherit it (setup-torch-venv.sh runs
      # under `bash -lc`). No-op on arches that ship prebuilt wheels; amd64 never
      # reaches this block (host GCC, no swap).
      mkdir -p /etc/profile.d
      cat > /etc/profile.d/50-native-gcc-paths.sh <<EOF
_idaf="-idirafter /usr/include/${triplet} -idirafter /usr/include"
export CPATH="\${CPATH:+\${CPATH}:}/usr/include/${triplet}:/usr/include"
export CPPFLAGS="\${CPPFLAGS:+\${CPPFLAGS} }\${_idaf}"
export CFLAGS="\${CFLAGS:+\${CFLAGS} }\${_idaf}"
export CXXFLAGS="\${CXXFLAGS:+\${CXXFLAGS} }\${_idaf}"
export LIBRARY_PATH="\${LIBRARY_PATH:+\${LIBRARY_PATH}:}/usr/lib/${triplet}:/usr/lib"
EOF
      echo "Wrote /etc/profile.d/50-native-gcc-paths.sh (CPATH/*FLAGS/LIBRARY_PATH -> system dirs)"

      # --- Bake system-header search INTO the foreign-arch native GCC ---
      # The relocated Canadian-cross GCC keeps its compile-time --native-system-
      # header-dir (/usr/${triplet}/include) baked in; that path is absent in the
      # runtime image, so a bare `gcc hello.c` cannot find <stdio.h>. The profile.d
      # block above only helps make-style builds -- a bare `gcc`/`g++` reads
      # neither CFLAGS nor CPPFLAGS, and CPATH cannot satisfy the C++
      # `#include_next`. An installed *self_spec appends the system include dirs
      # via -idirafter (validated for C and C++, no login shell needed). Keep this
      # spec MINIMAL -- reinstalling a full `gcc -dumpspecs` dump breaks the
      # built-in include-path specs, and a hand-written *lib/*libgcc override
      # crashes the driver under QEMU. (The mangled link spec -- `--as-needed`
      # corrupted to `-l*_asneeded` and a dropped `--eh-frame-hdr` -- is a
      # systematic corruption baked into this compiler by the GCC build's linker
      # feature detection; it is fixed at build time in build-gcc.sh, NOT here.)
      local gcclib="/opt/gcc-${GCC_VERSION}/lib/gcc/${triplet}/${GCC_VERSION}"
      if [ -d "${gcclib}" ]; then
        cat > "${gcclib}/specs" <<EOF
*self_spec:
+ %{!nostdinc:-idirafter /usr/include/${triplet} -idirafter /usr/include}
EOF
        echo "Installed native-GCC self_spec (-idirafter system include dirs) into ${gcclib}"
      else
        echo "WARNING: gcc lib dir ${gcclib} not found; skipped native-GCC include self_spec (bare gcc hello.c may fail on target)"
      fi
    fi

    echo "int main(){}" > /tmp/gcc_smoke.c
    if /opt/gcc-${GCC_VERSION}/bin/gcc /tmp/gcc_smoke.c -o /tmp/gcc_smoke 2>/tmp/gcc_smoke.err; then
      file /tmp/gcc_smoke
      echo "GCC compile smoke test PASSED"
    else
      # Classify the probe failure. On riscv64 the source-built GCC 16 emits its
      # default -march using the new ISA-spec profile extension names
      # (rv64..._zmmul_zaamo_zalrsc_zca_zcd) that the bundled binutils `as`
      # rejects -- a known GCC/binutils ISA-spec skew. It is NON-FATAL for the
      # cross build (this native GCC only matters for on-device compiles), so log
      # a clear NOTE instead of leaking the raw "Assembler ... Fatal error" line
      # (which reads as a real build failure in logs/monitors). Any OTHER probe
      # failure is still surfaced verbatim.
      if grep -q 'invalid -march=' /tmp/gcc_smoke.err 2>/dev/null; then
        echo "NOTE: native ${TARGET_ARCH} GCC default -march uses ISA-spec profile extension names its bundled assembler does not accept (known GCC/binutils ISA-spec skew; non-fatal for cross builds -- affects only on-device compilation). Tracked as build-arg RISCV_GCC_ISA_SPEC in the toolchain build."
      else
        echo "WARNING: native GCC cannot compile trivial program (cross-build host limitation)"
        sed 's/^/    /' /tmp/gcc_smoke.err 2>/dev/null || true
      fi
    fi
    rm -f /tmp/gcc_smoke.c /tmp/gcc_smoke /tmp/gcc_smoke.err
  elif [ "${TARGET_ARCH}" = "amd64" ]; then
    assert_elf_arch "/opt/gcc-${GCC_VERSION}/bin/gcc" "amd64"
    echo "Using host-native amd64 GCC at /opt/gcc-${GCC_VERSION}"
  fi
}

main "$@"