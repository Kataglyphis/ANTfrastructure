#!/usr/bin/env bash
set -euo pipefail
# verify-critical-fixes.sh — the host half of the critical-fixes battery: every
# check here reads the REPO TREE, so preflight can run it off-target. The probes
# that only mean anything inside a built image live in
# 06-packaging/smoke-critical-fixes.sh.
# docs/cross-build-verification.md#the-in-image-half-of-critical-fixes

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${REPO_ROOT}/linux/scripts/06-packaging/smoke-common.sh"

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
  # Pins the native-GCC system-path fix. See docs/cross-build-verification.md.
  # The helper is inlined here to avoid pulling common.sh's dependency chain.
  local stv="${REPO_ROOT}/linux/scripts/06-packaging/setup-torch-venv.sh"
  local swp="${REPO_ROOT}/linux/scripts/06-packaging/swap-native-gcc.sh"
  local dep="${REPO_ROOT}/linux/scripts/03-media/runtime/install-deps.sh"

  # -idirafter must reach C AND C++ in both the in-script env and profile.d (CPATH alone doesn't fix C++ #include_next).
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
  # apt numpy must NOT be seeded into the venv (collides with uv's built wheel).
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

  # Cache: must use local/inline, NOT the dead registry -buildcache ref.
  # Match the real code token ${tag}-buildcache, not prose that mentions it.
  if grep -q 'type=local' "${csb}" 2>/dev/null && ! grep -qF '${tag}-buildcache' "${csb}" 2>/dev/null; then
    pass "cross-stage-build.sh uses local/inline cache (no dead -buildcache ref)"
  else
    fail "cross-stage-build.sh reverted to the self-defeating registry -buildcache"
  fi
    # No launcher may point at BARE sccache — it aborts on internal errors where
    # ccache execs the compiler. This class shipped inert repeatedly; gate it.
    local ccsh="${REPO_ROOT}/linux/scripts/01-core/compiler-cache.sh"
    # Assert the DECISION (always sccache, never UNCACHED), not the spelling.
    # Every writer must resolve to some sccache; none may fall back to empty.
    if grep -qE '(RUSTC_WRAPPER|CMAKE_C(XX)?_COMPILER_LAUNCHER)="\$\{[A-Za-z_]+:-\}"' "${ccsh}" 2>/dev/null; then
      fail "compiler-cache.sh can leave a launcher EMPTY; the standing decision is always-sccache"
    elif grep -q '_sc_launcher="sccache"' "${ccsh}" 2>/dev/null \
         && grep -q 'sccache-launcher.sh' "${ccsh}" 2>/dev/null; then
      pass "compiler-cache.sh resolves the guarded launcher and falls back to sccache, never to uncached"
    else
      fail "compiler-cache.sh no longer resolves a guarded launcher with an sccache fallback"
    fi
    # Repo-wide: no bare ="sccache" launcher export. Use compiler_cache_launcher()
    # or the ${...:-sccache} fallback form.
    local _bad_sccache
    _bad_sccache="$(grep -rlE '(RUSTC_WRAPPER|CMAKE_C(XX)?_COMPILER_LAUNCHER|CMAKE_CUDA_COMPILER_LAUNCHER|CMAKE_HIP_COMPILER_LAUNCHER)="sccache"' "${REPO_ROOT}/linux/scripts/" --include='*.sh' 2>/dev/null | grep -v 'verify-critical-fixes.sh' | sort -u || true)"
    if [ -n "${_bad_sccache}" ]; then
      fail "bare sccache launcher export found (should use compiler_cache_launcher()): ${_bad_sccache}"
    else
      pass "no bare sccache launcher exports in linux/scripts/ (all go through compiler_cache_launcher)"
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
  # smoke-vulkan must NOT be invoked in build stages: it probes the full Vulkan
  # SDK this cross-build never installs, so it can only ever fail a build.
  if grep -rlE 'bash .*smoke-vulkan\.sh' "${REPO_ROOT}"/linux/Dockerfile.* 2>/dev/null | grep -q .; then
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

  # Stage build+push retries transient failures.
  if grep -q '_cross_stage_push_error_is_transient' "${csb}" && grep -q 'PUSH_MAX_ATTEMPTS' "${csb}"; then
    pass "cross-stage-build.sh retries transient pushes (A1)"
  else
    fail "cross-stage-build.sh lost the transient push-retry (A1 regression)"
  fi

  # Runtime pushes go through runtime_push_tag (which retries), not bare push.
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

  # The multi-arch manifest push is retried too.
  if grep -qE 'retry .*manifest push' "${brm}"; then
    pass "build-runtime-manifest.sh retries the manifest push (A1)"
  else
    fail "build-runtime-manifest.sh manifest push is not retried (A1 regression)"
  fi

  # The transient classifier must accept network drops and reject build errors.
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

  # Per-run stage-log truncation (guarded by the .run marker / CROSS_RUN_ID).
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

  # build-gcc.sh pins riscv64 --with-isa-spec so the shipped native GCC's
  # default -march stays assembler-compatible.
  if grep -qE '^[[:space:]]*riscv64-\*\)' "${gcc}" && \
     grep -q -- '--with-isa-spec=' "${gcc}" && \
     grep -q 'RISCV_GCC_ISA_SPEC-20191213' "${gcc}"; then
    pass "build-gcc.sh pins riscv64 --with-isa-spec (default 20191213) (A2)"
  else
    fail "build-gcc.sh lost the riscv64 ISA-spec pin (A2 regression)"
  fi

  # The riscv64 torch-wheel fallback drops a sentinel the runtime smoke keys on.
  if grep -qF '.torch-missing' "${venv}"; then
    pass "setup-torch-venv.sh writes the /opt/venv/.torch-missing sentinel (A3)"
  else
    fail "setup-torch-venv.sh lost the torch-less sentinel (A3 regression)"
  fi

  # Expected build noise stays classified as NOTE, not surfaced as failure.
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

fix10_libstdcxx_nostdinc_2026_08() {
  # The PR100017 Canadian-cross fix (docs/upstream-libstdcxx-c++23-nostdinc++.md).
  # build-gcc.sh patches -nostdinc++ into c++23 Makefile.in, self-retiring when
  # upstream adds the flag. No static gate saw the block — pin it here.
  local bg="${REPO_ROOT}/linux/scripts/02-toolchain/build-gcc.sh"
  if grep -q "src/c++23/Makefile.in" "${bg}" \
     && grep -q -- "-std=gnu++23 -nostdinc++" "${bg}"; then
    pass "build-gcc.sh carries the PR100017 -nostdinc++ c++23 module sed (fix10)"
  else
    fail "build-gcc.sh LOST the PR100017 -nostdinc++ patch block — Canadian-cross std module would silently ship EMPTY (fix10 regression)"
  fi
  if grep -q "AM_CXXFLAGS layout changed" "${bg}"; then
    pass "the -nostdinc++ sed still dies loud on GCC layout change (fix10)"
  else
    fail "the -nostdinc++ sed lost its loud-failure die (fix10 regression)"
  fi
  # The idempotence gate is what makes the patch self-retiring on a fixed GCC.
  if grep -qE '!\s*grep -q -- .-nostdinc\+\+' "${bg}"; then
    pass "the -nostdinc++ sed is idempotence-gated / self-retiring (fix10)"
  else
    fail "the -nostdinc++ sed lost its idempotence gate (fix10 regression)"
  fi
}

echo "=== Critical Fixes: host tree checks ==="
echo ""

FIX_FUNCS=(fix5_gst_geometry_include fix6_native_gcc_system_paths fix7_hardening_2026_07 fix8_push_retry_2026_07 fix9_riscv_isaspec_and_noise_2026_07 fix10_libstdcxx_nostdinc_2026_08)
for _fix_fn in "${FIX_FUNCS[@]}"; do
  "${_fix_fn}"
  echo ""
done

smoke_summary
