#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"
# Reuse the shared pass/fail/smoke_summary harness instead of a local copy.
# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${REPO_ROOT}/linux/scripts/06-packaging/smoke-common.sh"

fix1_python_pc() {
  echo "--- Fix 1: gst-python staged libpython (python pkg-config rewrite) ---"
  local found=0 arch pc
  for arch in $(arch_list_to_words "${CROSS_DEFAULT_ARCHES:-amd64,arm64,riscv64}"); do
    pc="/opt/python-cross/${arch}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR:-3.14}.pc"
    if [ -f "${pc}" ]; then
      found=1
      if grep -q '^prefix=/opt/python-cross' "${pc}"; then
        pass "python-3.14.pc prefix points to /opt/python-cross (${arch})"
      else
        fail "python-3.14.pc prefix does NOT point to /opt/python-cross (${arch})"
      fi
      if grep -q '^libdir=/opt/python-cross' "${pc}" 2>/dev/null || \
         grep -q 'libdir=${prefix}/lib' "${pc}" 2>/dev/null; then
        pass "python-3.14.pc libdir resolves inside staging tree (${arch})"
      else
        fail "python-3.14.pc libdir may point outside staging tree (${arch})"
      fi
    fi
  done
  # `|| true`-terminated: as the function's LAST statement, a bare AND-list
  # makes the HEALTHY case (found=1) return 1 — under set -e that killed the
  # script right here, silently skipping fixes 2-9 and the summary whenever it
  # ran where the staged payloads actually exist (i.e. inside the images).
  { [ "${found}" -eq 0 ] && echo "  SKIP: no per-arch python-3.14.pc found (not in cross-compiler context)"; } || true
}

fix2_abseil_span() {
  echo "--- Fix 2: libcamera abseil header in LiteRT ---"
  local dirs=(
    "/opt/litert/include"
    "/usr/local/include/tensorflow/lite"
    "/usr/local/include/litert"
  )
  local found=0 dir
  for dir in "${dirs[@]}"; do
    if [ -f "${dir}/absl/types/span.h" ]; then
      pass "absl/types/span.h found in ${dir}"
      found=1
      break
    fi
  done
  if [ "${found}" -eq 0 ]; then
    for dir in "${dirs[@]}"; do
      if [ -d "${dir}" ]; then
        if find "${dir}" -name "span.h" -path "*/absl/types/*" 2>/dev/null | grep -q .; then
          pass "absl/types/span.h found via search in ${dir}"
          found=1
          break
        fi
      fi
    done
  fi
  if [ "${found}" -eq 0 ]; then
    if [ -d "/opt/litert" ] || [ -d "/usr/local/include/tensorflow" ]; then
      fail "absl/types/span.h NOT found in any LiteRT include directory"
    else
      echo "  SKIP: no LiteRT include directories found"
    fi
  fi
}

fix3_libdynload_dangling() {
  echo "--- Fix 3: cross lib-dynload no dangling symlinks ---"
  local found=0 arch dir count
  for arch in $(arch_list_to_words "${CROSS_DEFAULT_ARCHES:-amd64,arm64,riscv64}"); do
    dir="/opt/python-cross/${arch}/usr/local/lib/python${PYTHON_MAJOR_MINOR:-3.14}/lib-dynload"
    if [ -d "${dir}" ]; then
      found=1
      count=$(find "${dir}" -xtype l 2>/dev/null | wc -l)
      if [ "${count}" -eq 0 ]; then
        pass "No dangling symlinks in lib-dynload (${arch})"
      else
        fail "${count} dangling symlinks found in lib-dynload (${arch})"
        find "${dir}" -xtype l 2>/dev/null | while read -r sl; do
          echo "    dangling: ${sl}" >&2
        done
      fi
    fi
  done
  # Same class-5 guard as fix1 above: healthy case must not become exit 1.
  { [ "${found}" -eq 0 ] && echo "  SKIP: no per-arch lib-dynload found (not in cross-compiler context)"; } || true
}

fix4_cc_dumpmachine() {
  echo "--- Fix 4: cross GCC architecture guard (cc target triple) ---"
  local arch
  arch="$(canonical_target_arch "${TARGET_ARCH:-${TARGETARCH:-}}" 2>/dev/null || true)"
  if [ -n "${arch}" ]; then
    local expected
    expected="$(arch_uname_name_for "${arch}")"
    if command -v cc >/dev/null 2>&1; then
      local actual
      actual="$(cc -dumpmachine 2>/dev/null | cut -d- -f1 || echo '')"
      if [ "${actual}" = "${expected}" ]; then
        pass "cc -dumpmachine reports ${actual} (expected ${expected})"
      else
        fail "cc -dumpmachine reports ${actual} (expected ${expected})"
      fi
      if command -v readelf >/dev/null 2>&1; then
        local cc_bin elf_expected elf_actual
        cc_bin="$(command -v cc)"
        elf_expected="$(arch_elf_machine_grep_for "${arch}" 2>/dev/null || echo '')"
        elf_actual="$(elf_machine_name "${cc_bin}" 2>/dev/null || echo '')"
        if [ -n "${elf_expected}" ] && echo "${elf_actual}" | grep -qF "${elf_expected}"; then
          pass "cc ELF machine matches expected ${elf_expected}"
        elif [ -n "${elf_actual}" ]; then
          fail "cc ELF machine is ${elf_actual} (expected ${elf_expected})"
        fi
      fi
    else
      echo "  SKIP: cc not found"
    fi
  else
    echo "  SKIP: cannot determine target arch"
  fi
}

fix5_gst_geometry_include() {
  echo "--- Fix 5: OpenCV 5 GStreamer compat (geometry.hpp include) ---"
  local dirs=(
    "${REPO_ROOT}/linux/scripts/03-media/build/gstreamer"
    "/opt/scripts/03-media/build/gstreamer"
  )
  local found=0 src="" dir
  for dir in "${dirs[@]}"; do
    if [ -d "${dir}" ]; then
      src="$(find "${dir}" -name "gstsegmentation.cpp" -type f 2>/dev/null | head -1 || echo '')"
      if [ -n "${src}" ] && [ -f "${src}" ]; then
        found=1
        break
      fi
    fi
  done
  if [ "${found}" -eq 1 ]; then
    if grep -q '#include <opencv2/geometry.hpp>' "${src}" 2>/dev/null; then
      pass "gstsegmentation.cpp includes opencv2/geometry.hpp"
    else
      fail "gstsegmentation.cpp missing #include <opencv2/geometry.hpp>"
      echo "  Source: ${src}" >&2
    fi
  else
    echo "  SKIP: gstsegmentation.cpp not found (checking if patch applies at build time)"
    if [ -f "${REPO_ROOT}/linux/scripts/03-media/build/gstreamer/common/patch-gstreamer-sources.sh" ]; then
      if grep -q "geometry.hpp" "${REPO_ROOT}/linux/scripts/03-media/build/gstreamer/common/patch-gstreamer-sources.sh" 2>/dev/null; then
        pass "patch-gstreamer-sources.sh contains geometry.hpp patch"
      else
        fail "patch-gstreamer-sources.sh missing geometry.hpp reference"
      fi
    fi
  fi
}

fix6_native_gcc_system_paths() {
  echo "--- Fix 6: native-GCC system header/lib paths for torch-venv source builds ---"
  # Locks in bugs D & E from the 2026-07 cross rebuild (see
  # docs/cross-build-verification.md). The relocated native GCC/G++ cannot find
  # /usr/include for QEMU source builds; the canonical helper is
  # append_cross_idirafter in 01-core/common.sh, inlined here in the torch/android
  # stages to avoid pulling common.sh's dependency chain into them.
  local stv="${REPO_ROOT}/linux/scripts/06-packaging/setup-torch-venv.sh"
  local swp="${REPO_ROOT}/linux/scripts/06-packaging/swap-native-gcc.sh"
  local dep="${REPO_ROOT}/linux/scripts/03-media/runtime/install-deps.sh"

  # D: -idirafter must reach C AND C++ compiles in both the in-script env and the
  # persisted profile.d (CPATH alone does not fix C++ #include_next).
  if grep -q 'idirafter /usr/include' "${stv}" 2>/dev/null && \
     grep -qE 'export CXXFLAGS=.*idaf|CXXFLAGS.*idirafter' "${stv}" 2>/dev/null; then
    pass "setup-torch-venv.sh injects -idirafter into CXXFLAGS (C++ #include_next)"
  else
    fail "setup-torch-venv.sh lost the -idirafter CXXFLAGS injection (bug D regression)"
  fi
  if grep -q 'idirafter /usr/include' "${swp}" 2>/dev/null; then
    pass "swap-native-gcc.sh profile.d writes -idirafter system paths"
  else
    fail "swap-native-gcc.sh lost the -idirafter profile.d injection (bug D regression)"
  fi
  # D: Pillow needs jpeglib.h -> libjpeg-dev in the final-stage target packages.
  if grep -qE '^[[:space:]]*libjpeg-dev' "${dep}" 2>/dev/null; then
    pass "install-deps.sh installs libjpeg-dev (Pillow jpeglib.h)"
  else
    fail "install-deps.sh no longer installs libjpeg-dev (bug D regression)"
  fi
  # E: apt numpy must NOT be seeded into the venv (collides with uv's built wheel).
  if grep -qE 'for pkg in .*\bnumpy\b' "${stv}" 2>/dev/null; then
    fail "setup-torch-venv.sh re-seeds apt numpy into the venv (bug E regression)"
  else
    pass "setup-torch-venv.sh does not seed apt numpy into the venv"
  fi
}

fix7_hardening_2026_07() {
  echo "--- Fix 7: cross-build hardening (cache, base pin, non-root, apt retry, mount scope) ---"
  local csb="${REPO_ROOT}/linux/scripts/01-core/cross-stage-build.sh"
  local dbase="${REPO_ROOT}/linux/Dockerfile.base"
  local dtorch="${REPO_ROOT}/linux/Dockerfile.torch"
  local bimg="${REPO_ROOT}/linux/scripts/01-core/base-image.sh"
  local venv="${REPO_ROOT}/linux/scripts/01-core/versions.env"

  # Cache: must use a working cache backend (local/inline), NOT the self-defeating
  # registry -buildcache ref whose --cache-to was gated out of existence.
  # Match the real code token ${tag}-buildcache (the dead ref), not prose that
  # merely mentions "-buildcache" while explaining why it was removed.
  if grep -q 'type=local' "${csb}" 2>/dev/null && ! grep -qF '${tag}-buildcache' "${csb}" 2>/dev/null; then
    pass "cross-stage-build.sh uses local/inline cache (no dead -buildcache ref)"
  else
    fail "cross-stage-build.sh reverted to the self-defeating registry -buildcache"
  fi
  # Base: the only floating external base must be digest-pinned (multi-arch list).
  if grep -qE '^FROM ubuntu:\$\{UBUNTU_VERSION\}@\$\{UBUNTU_DIGEST\}' "${dbase}" 2>/dev/null && \
     grep -qE '^UBUNTU_DIGEST=sha256:' "${venv}" 2>/dev/null; then
    pass "Dockerfile.base pins ubuntu by manifest-list digest (UBUNTU_DIGEST)"
  else
    fail "Dockerfile.base ubuntu base is no longer digest-pinned"
  fi
  # Non-root: the runtime user must own its WORKDIR/VOLUME.
  if grep -qE 'chown -R kataglyphis(:kataglyphis)? \$\{WORKDIR\}' "${dtorch}" 2>/dev/null; then
    pass "Dockerfile.torch chowns WORKDIR to the non-root user"
  else
    fail "Dockerfile.torch no longer chowns WORKDIR (non-root user cannot write it)"
  fi
  # apt: image-wide retries for flaky QEMU networks.
  if grep -q 'apt.conf.d/80-retries' "${bimg}" 2>/dev/null; then
    pass "base-image.sh installs image-wide apt retries"
  else
    fail "base-image.sh lost the image-wide apt retry config"
  fi
  # Cache scope: base RUNs must NOT bind-mount the whole linux/scripts tree
  # (that folds every script's checksum into the base cache key).
  if grep -qE -- '--mount=type=bind,source=linux/scripts,target' "${dbase}" 2>/dev/null; then
    fail "Dockerfile.base re-introduced a whole-tree scripts bind mount (busts base cache)"
  else
    pass "Dockerfile.base bind-mounts only the script sub-trees it uses"
  fi
  # smoke-vulkan must NOT be invoked in any build stage: it probes the full
  # Vulkan SDK (/opt/vulkan/active, headers, loader) which this runtime-focused
  # cross-build never installs, so it can only ever fail a build (learned the
  # hard way in android + package). It stays a standalone host tool.
  if grep -rlE 'bash[^\n]*smoke-vulkan\.sh' "${REPO_ROOT}"/linux/Dockerfile.* 2>/dev/null | grep -q .; then
    fail "a Dockerfile RUNs smoke-vulkan.sh (no full Vulkan SDK here -> always fails)"
  else
    pass "smoke-vulkan.sh is not invoked in any build stage"
  fi
}

fix8_push_retry_2026_07() {
  echo "--- Fix 8: transient push retry + per-run stage logs (2026-07) ---"
  local csb="${REPO_ROOT}/linux/scripts/01-core/cross-stage-build.sh"
  local rbf="${REPO_ROOT}/linux/scripts/01-core/runtime-build-fns.sh"
  local brm="${REPO_ROOT}/linux/scripts/build-runtime-manifest.sh"

  # A1: stage build+push retries transient failures.
  if grep -q '_cross_stage_push_error_is_transient' "${csb}" && grep -q 'PUSH_MAX_ATTEMPTS' "${csb}"; then
    pass "cross-stage-build.sh retries transient pushes (A1)"
  else
    fail "cross-stage-build.sh lost the transient push-retry (A1 regression)"
  fi

  # A1: runtime image pushes go through the retry helper -- every `push "${tag}"`
  # line must be immediately preceded by a `retry ...` line (the only such push
  # lives inside runtime_push_tag; callers invoke that helper, not push directly).
  local _bare_pushes
  _bare_pushes="$(awk '
    /run .*push "\$\{tag\}"/ { if (prev !~ /retry/) c++ }
    { prev=$0 }
    END { print c+0 }' "${rbf}")"
  if grep -q '^runtime_push_tag()' "${rbf}" && [ "${_bare_pushes}" = "0" ]; then
    pass "runtime-build-fns.sh pushes via runtime_push_tag (A1)"
  else
    fail "runtime-build-fns.sh has a bare (unretried) image push (A1 regression)"
  fi

  # A1: the multi-arch manifest push is retried too.
  if grep -qE 'retry .*manifest push' "${brm}"; then
    pass "build-runtime-manifest.sh retries the manifest push (A1)"
  else
    fail "build-runtime-manifest.sh manifest push is not retried (A1 regression)"
  fi

  # A1: the transient classifier must accept network drops and reject build errors.
  local _fn _t
  _fn="$(sed -n '/^_cross_stage_push_error_is_transient() {/,/^}/p' "${csb}")"
  if [ -n "${_fn}" ]; then
    eval "${_fn}"
    _t="$(mktemp)"
    printf 'write tcp: use of closed network connection\n' > "${_t}"
    if _cross_stage_push_error_is_transient "${_t}"; then
      pass "classifier flags 'closed network connection' as transient"
    else
      fail "classifier no longer flags network drops as transient (A1 regression)"
    fi
    printf 'ERROR: process did not complete successfully: exit code: 1\n' > "${_t}"
    if _cross_stage_push_error_is_transient "${_t}"; then
      fail "classifier wrongly treats a build error as transient (A1 regression)"
    else
      pass "classifier treats a real build error as non-transient"
    fi
    rm -f "${_t}"
  else
    fail "could not extract _cross_stage_push_error_is_transient for the functional check"
  fi

  # B1: per-run stage-log truncation (guarded by the .run marker / CROSS_RUN_ID).
  if grep -q 'CROSS_RUN_ID' "${csb}" && grep -q '\.run' "${csb}"; then
    pass "cross-stage-build.sh truncates stage logs per run (B1)"
  else
    fail "cross-stage-build.sh lost per-run log truncation (B1 regression)"
  fi
}

fix9_riscv_isaspec_and_noise_2026_07() {
  echo "--- Fix 9: riscv64 ISA-spec pin (A2) + torch-less sentinel (A3) + benign-noise classifiers (B2) ---"
  local gcc="${REPO_ROOT}/linux/scripts/02-toolchain/build-gcc.sh"
  local venv="${REPO_ROOT}/linux/scripts/06-packaging/setup-torch-venv.sh"
  local rw="${REPO_ROOT}/linux/scripts/03-media/runtime/repair-wheels.sh"
  local swap="${REPO_ROOT}/linux/scripts/06-packaging/swap-native-gcc.sh"

  # A2: build-gcc.sh pins the riscv64 ISA spec so the shipped native GCC's
  # default -march stays assembler-compatible. Assert BOTH the riscv64 case arm
  # and the --with-isa-spec flag with its 20191213 default survive together.
  if grep -qE '^[[:space:]]*riscv64-\*\)' "${gcc}" && \
     grep -q -- '--with-isa-spec=' "${gcc}" && \
     grep -q 'RISCV_GCC_ISA_SPEC-20191213' "${gcc}"; then
    pass "build-gcc.sh pins riscv64 --with-isa-spec (default 20191213) (A2)"
  else
    fail "build-gcc.sh lost the riscv64 ISA-spec pin (A2 regression)"
  fi

  # A3: the riscv64 torch-wheel fallback drops a loud sentinel the runtime smoke
  # keys on -- a silently torch-less image must never look healthy.
  if grep -qF '.torch-missing' "${venv}"; then
    pass "setup-torch-venv.sh writes the /opt/venv/.torch-missing sentinel (A3)"
  else
    fail "setup-torch-venv.sh lost the torch-less sentinel (A3 regression)"
  fi

  # B2: expected build noise stays classified as NOTE, not surfaced as failure.
  if grep -q 'too-recent versioned symbols' "${rw}"; then
    pass "repair-wheels.sh classifies benign auditwheel glibc mismatch (B2)"
  else
    fail "repair-wheels.sh lost the benign-auditwheel classifier (B2 regression)"
  fi
  if grep -q 'invalid -march=' "${swap}"; then
    pass "swap-native-gcc.sh classifies benign riscv64 -march skew (B2)"
  else
    fail "swap-native-gcc.sh lost the benign -march classifier (B2 regression)"
  fi
}

echo "=== Critical Fixes Regression Tests ==="
echo ""

FIX_FUNCS=(fix1_python_pc fix2_abseil_span fix3_libdynload_dangling fix4_cc_dumpmachine fix5_gst_geometry_include fix6_native_gcc_system_paths fix7_hardening_2026_07 fix8_push_retry_2026_07 fix9_riscv_isaspec_and_noise_2026_07)
for _fix_fn in "${FIX_FUNCS[@]}"; do
  "${_fix_fn}"
  echo ""
done

smoke_summary
