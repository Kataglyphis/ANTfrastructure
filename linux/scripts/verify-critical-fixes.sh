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

# fix11: ORT has one source, the chain (owner rule 2026-09-23). A DENYLIST over this repo's scripts; NOT covered:
# an upstream bump that fetches ORT by itself (G2/G1). docs/windows-build-invariants.md#onnx-runtime-has-exactly-one-source-the-chain-owner-rule-2026-09-23

# "<consumer script>|<call>": each ORT consumer calls its gate exactly once (G2, or its own configure gate).
F11_GATE_CALLS=(
  "windows/scripts/build/Build-OpencvFromSource.ps1|Assert-ChainOrtOnly"
  "windows/scripts/build/Build-OnnxGenaiFromSource.ps1|Assert-ChainOrtOnly"
  "windows/scripts/build/Build-FfmpegFromSource.ps1|Assert-ChainOrtOnly"
  "windows/scripts/build/Build-GstreamerFromSource.ps1|Assert-ChainOrtOnly"
  "windows/scripts/build/Build-OrtAmdgpuEpFromSource.ps1|Assert-ChainOrtOnly"
  "windows/scripts/build/Build-OpencvFromSource.ps1|Get-OpencvOrtConfigureFinding"
  "windows/scripts/build/Build-OnnxGenaiFromSource.ps1|Get-GenaiOrtConfigureFinding"
  "linux/scripts/03-media/build/opencv/build-opencv.sh|ort_assert_chain_only"
  "linux/scripts/03-media/build/ffmpeg/build-ffmpeg.sh|ort_assert_chain_only"
  "linux/scripts/03-media/build/gstreamer/common/build-gstreamer-monorepo.sh|ort_assert_chain_only"
  "linux/scripts/03-media/verify-genai-ort.sh|ort_assert_chain_only"
  "linux/scripts/03-media/build/opencv/build-opencv.sh|opencv_ort_assert_configure"
  "linux/scripts/03-media/build/opencv/build-opencv.sh|opencv_ort_assert_installed"
  "linux/scripts/03-media/build/ffmpeg/build-ffmpeg.sh|ffmpeg_ort_link_findings"
  "linux/scripts/03-media/build/gstreamer/common/build-gstreamer-monorepo.sh|gst_onnx_ort_findings"
  "linux/scripts/03-media/runtime/validate-media-runtime.sh|ort_is_denied_soname"
  "linux/scripts/03-media/runtime/validate-media-runtime.sh|ort_apt_plan_gate"
  "linux/scripts/03-media/runtime/validate-media-runtime.sh|ort_dpkg_gate"
)
# The G2 helpers: bind-mounted per file into the consumer RUNs, never baked into a shared module closure. Both sit
# apart from the census (edited without re-keying a consumer build) and outside every dir an image copies whole.
F11_WIN_G2_MODULE="windows/scripts/modules/WindowsOrtProvenance.Build.psm1"
F11_WIN_CENSUS_MODULE="windows/scripts/modules/WindowsOrtProvenance.Common.psm1"
F11_LINUX_G2_HELPER="linux/scripts/03-media/ort-provenance.sh"
# A Linux RUN containing one of these builds an ORT consumer and must mount the G2 helper.
F11_LINUX_G2_RUNS=("build-opencv.sh" "build-ffmpeg.sh" "build-gstreamer-stage.sh" "verify-genai-ort.sh")
F11_GENAI_BUILD="linux/scripts/03-media/build/onnxruntime/build/60-build-genai.sh"

# _f11_scan_files: the hub's build inputs on both lanes (repo-relative, NUL-separated, sorted), minus suites
# and staging dirs.
_f11_scan_files() {
  (cd "${REPO_ROOT}" && find windows linux/scripts linux/Dockerfile.* shared .github \
      \( -name tests -o -name upstream -o -name qnn-sdk -o -name downloads -o -name __pycache__ \
      -o -path linux/scripts/verify-critical-fixes.sh \) -prune \
      -o -type f \( -name '*.ps1' -o -name '*.psm1' -o -name '*.sh' -o -name 'Dockerfile*' -o -name '*.env' \
      -o -name '*.txt' -o -name '*.yml' -o -name '*.yaml' -o -name '*.toml' -o -name '*.cmake' -o -name '*.py' \) \
      -print0 2>/dev/null | LC_ALL=C sort -z) || true
}

# _f11_corpus <out>: "<path>:<line>:<text>" for every non-comment line of the scan set (# lines and
# PowerShell <# #> blocks dropped; trailing comments kept, so positive checks match exact code shapes).
_f11_corpus() {
  _f11_scan_files | (cd "${REPO_ROOT}" && xargs -0 awk '
    FNR == 1 { blk = 0 }
    blk { if ($0 ~ /#>/) blk = 0; next }
    FILENAME ~ /\.psm?1$/ && $0 ~ /^[[:space:]]*<#/ { if ($0 !~ /#>/) blk = 1; next }
    $0 ~ /^[[:space:]]*#/ { next }
    { sub(/\r$/, ""); print FILENAME ":" FNR ":" $0 }') > "$1" 2>/dev/null || true
}

# The corpus rules are QUEUED by the fix11_ort_* checks and judged by _f11_judge in ONE awk pass.
# docs/onnxruntime-single-source.md#how-g4-runs-one-judging-pass

# _f11_rule <kind> <what> <re> <re2> <re3> <not> <path-in> <path-out> [<want> <name> <re-b>]: queue one rule.
_f11_rule() {
  local row
  printf -v row '%s\t' "$@"
  _F11_RULES+=("${row%$'\t'}")
}

# _f11_deny <what> <re> [<re2> <re3> <not> <path-in> <path-out>]: PASS when no corpus line's LOWER-CASED text
# matches every given ERE and not <not>, on a path matching <path-in> and not <path-out> ('' = unused).
_f11_deny() {
  _f11_rule deny "$1" "$2" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
}

# _f11_require <path> <re> <want> <what> [<not>]: <want> ("N" exactly, "N+" at least) live lines of <path>
# match <re> and not <not>. A <path> starting with ^ is an ERE over paths.
_f11_require() {
  local scope="$1"
  case "${scope}" in
    ^*) ;;
    *) scope="^${scope//./\\.}\$" ;;
  esac
  _f11_rule require "$4" "$2" '' '' "${5:-}" "${scope}" '' "$3" "$1"
}

# _f11_pair <what> <re> <re-b>: every file with a live line matching <re> has one matching <re-b> too.
_f11_pair() {
  _f11_rule pair "$1" "$2" '' '' '' '' '' '' '' "$3"
}

# _f11_count <key> <path> <re>: how many live lines of <path> match <re>, into _F11_N[<key>] once judged.
_f11_count() {
  _F11_N["$1"]=0
  _f11_rule count "$1" "$3" '' '' '' "^${2//./\\.}\$"
}

# _f11_judge <corpus>: every queued rule in one pass, a verdict per rule in queue order. The regexes change
# per rule, never per line: gawk recompiles a dynamic regex whenever its site sees a new one.
_f11_judge() {
  local rules="$1.rules" out="$1.verdicts" v m n seen=0
  printf '%s\n' "${_F11_RULES[@]}" > "${rules}"
  awk -v RF="${rules}" '
    FILENAME == RF { RULE[++nr] = $0; next }
    { p = substr($0, 1, index($0, ":") - 1); t = substr($0, index($0, ":") + 1)
      if (p != cur) { FP[++nf] = cur = p; FA[nf] = FNR }
      FZ[nf] = FNR; T[FNR] = tolower(substr(t, index(t, ":") + 1)); L[FNR] = $0 }
    END { for (r = 1; r <= nr; r++) judge(RULE[r]) }
    function judge(row,   F, f, i, n, fn, fb, hits, bad) {
      split(row, F, "\t"); RE = F[3]; RE2 = F[4]; RE3 = F[5]; NOT = F[6]; PI = F[7]; PX = F[8]; B = F[11]
      for (f = 1; f <= nf; f++) {
        if ((PI != "" && FP[f] !~ PI) || (PX != "" && FP[f] ~ PX)) continue
        fn = fb = 0
        for (i = FA[f]; i <= FZ[f]; i++) {
          if (T[i] ~ RE && (RE2 == "" || T[i] ~ RE2) && (RE3 == "" || T[i] ~ RE3) && (NOT == "" || T[i] !~ NOT)) {
            fn++; if (++n <= 5) hits = hits L[i] " " }
          if (B != "" && T[i] ~ B) fb++ }
        if (fn && !fb) bad = bad FP[f] " " }
      if (F[1] == "count") print "N\t" F[2] "\t" (n + 0)
      else if (F[1] == "pair") verdict(bad == "", F[2], "violated by: " bad)
      else if (F[1] == "deny") verdict(!n, F[2], "violated by: " hits)
      else verdict(F[9] ~ /\+$/ ? n >= F[9] + 0 : n == F[9] + 0, F[2], F[10] " has " (n + 0) " matching line(s), expected " F[9]) }
    function verdict(ok, what, why) { print (ok ? "PASS" : "FAIL") "\tfix11: " what (ok ? "" : " -- " why) }
  ' "${rules}" "$1" > "${out}" 2>/dev/null || true
  while IFS=$'\t' read -r v m n; do
    seen=$((seen + 1))
    case "${v}" in
      PASS) pass "${m}" ;;
      N) _F11_N["${m}"]="${n}" ;;
      *) fail "${m}" ;;
    esac
  done < "${out}"
  if [ "${seen}" -ne "${#_F11_RULES[@]}" ]; then
    fail "fix11: the corpus rules got ${seen} verdict(s) for ${#_F11_RULES[@]} rule(s) -- the judging pass broke"
  fi
}

# _f11_verdict <hits> <what>: PASS when no line hit, else FAIL naming the first five.
_f11_verdict() {
  if [ -z "$1" ]; then
    pass "fix11: $2"
  else
    fail "fix11: $2 -- violated by: $(printf '%s\n' "$1" | head -n 5 | tr '\n' ' ')"
  fi
}

# _f11_nuget_refusal: the hub's NuGet facility throws on an ORT package id BEFORE it runs nuget install.
_f11_nuget_refusal() {
  local m="${REPO_ROOT}/windows/scripts/modules/WindowsOnnx.Common.psm1" order
  order="$(awk '/^function Install-OptionalNuGetPackage/ { p = 1; next } p && /^(function |Export-ModuleMember)/ { exit }
    p && /-match[[:space:]]+\$script:OrtNuGetIdPattern/ { if (!g) g = FNR } p && g && /throw/ && !t { t = FNR }
    p && /nuget install/ && !n { n = FNR } END { print ((g && t && n && t < n) ? "ok" : "bad") }' "${m}" 2>/dev/null || true)"
  if [ "${order}" = ok ] && grep -qiE -e "^[\$]script:OrtNuGetIdPattern = '[^']*onnxruntime" "${m}" 2>/dev/null; then
    pass "fix11: Install-OptionalNuGetPackage refuses an ORT package id before nuget install runs"
  else
    fail "fix11: ${m#"${REPO_ROOT}/"} lost the ORT refusal in Install-OptionalNuGetPackage (or it runs after nuget install)"
  fi
}

# _f11_so_map: the apt resolver's SONAME map denies libonnxruntime.so* and maps nothing to a distro ORT.
_f11_so_map() {
  local m="${REPO_ROOT}/linux/scripts/03-media/runtime/so-package-map.txt" v
  v="$(awk -F '\t' '/^[[:space:]]*(#|$)/ { next } tolower($2) ~ /onnxruntime/ { print "maps " $1 " to " $2 }
    $1 ~ /^libonnxruntime\.so\*?(\.\*)?$/ && $2 == "source-built" { d = 1 }
    END { if (!d) print "no libonnxruntime.so* -> source-built deny row" }' "${m}" 2>/dev/null || echo "${m} unreadable")"
  _f11_verdict "${v}" "so-package-map.txt denies libonnxruntime.so* and names no distro ORT package"
}

fix11_ort_fetch_denylist() {
  local c="$1" q="'" tok w
  _f11_deny "no OpenCV DOWNLOAD_ONNXRUNTIME[_GPU]=ON (dnn downloads a prebuilt ORT)" \
    "download_onnxruntime(_gpu)?(:bool)?=[\"${q}]?(on|1|true|yes)([^a-z0-9_]|\$)"
  _f11_deny "no ORT binary URL (PyPI, NuGet, a GitHub release, the pyke CDN, the aiinfra nightly feed)" \
    '(pythonhosted\.org|pypi\.org|nuget\.org)/[^[:space:]]*onnxruntime|github\.com/microsoft/onnxruntime(-genai)?/releases/download|cdn\.pyke\.io|pkgs\.dev\.azure\.com/aiinfra'
  # The refusing facility and G2's two detectors name the ids to catch them; nothing else may.
  _f11_deny "no Microsoft.ML.OnnxRuntime* / Windows ML NuGet package outside the refusing WindowsOnnx.Common facility" \
    'microsoft\.ml\.onnxruntime|microsoft\.(windows\.)?ai\.machinelearning' '' '' '' '' \
    "^(windows/scripts/modules/WindowsOnnx\\.Common\\.psm1|${F11_WIN_G2_MODULE//./\\.}|${F11_LINUX_G2_HELPER//./\\.})\$"
  # Deleting or patching the OS's own ORT silences smoke § 25's INBOX; a base that ships one keeps the old digest.
  _f11_deny "nothing deletes or patches an in-box ORT under C:\\Windows (keep WINDOWS_BASE_DIGEST instead)" \
    '(system32|syswow64|winsxs|windir|systemroot|c:.windows)' '(onnxruntime|windows\.ai\.machinelearning)' \
    '(remove-item|rename-item|move-item|copy-item|set-content|takeown|icacls|(^|[^a-z0-9_-])(del|erase|rm|ri|mv|cp|move|copy|ren)([^a-z0-9_-]|$)|\.(delete|move|copy|replace)[[:space:]]*[(])'
  _f11_nuget_refusal
  tok="(^|[[:space:]\"${q}(=,])onnxruntime([-_][a-z0-9]+)*([[:space:]\"${q}),=<>~!;]|\$)"
  _f11_deny "no pip/uv install of an onnxruntime* name that can reach PyPI (--no-index or a local wheel path only)" \
    'pip|(^|[^a-z])uv([^a-z]|$)' '(^|[^a-z])(install|download|wheel|add)([^a-z]|$)' "${tok}" '--no-index'
  # Distro package names only (chain files are libonnxruntime.so*/_providers_*), so no apt context is needed.
  tok="(^|[[:space:]\"${q}(=,])(libonnxruntime(-dev|-providers[a-z0-9-]*|[0-9][0-9a-z.+~-]*)|python3-onnxruntime[a-z0-9-]*)([[:space:]\"${q}),;|]|\\\\|\$)"
  _f11_deny "no apt libonnxruntime*/python3-onnxruntime* package named anywhere (install line, continuation line, package list)" \
    "${tok}"
  _f11_so_map
  _f11_deny "FFmpeg has no vendor libonnxruntime.pc fallback" \
    'ffmpeg_probe_pkg_config_feature[[:space:]]+"?libonnxruntime'
  w="$(_f11_env_writes "${c}")"
  # ort-sys skips the download only on exactly 1/true, and the FIRST set switch wins, even empty.
  _f11_verdict "$(printf '%s\n' "${w}" | grep -E -e ': (ort_lib_path|ort_strategy|ort_skip_download|cargo_net_offline|ort_offline)=' \
      | grep -vE -e ': (ort_skip_download|cargo_net_offline|ort_offline)=(1|true)$' || true)" \
    "nothing re-arms the ort crate download (ORT_LIB_PATH/ORT_STRATEGY set at all, a skip switch set to anything but 1/true)"
  _f11_verdict "$(printf '%s\n' "${w}" | grep -E -e ': (ort_lib_location|ort_dylib_path)=' \
      | grep -vE -e '^(windows/Dockerfile|linux/Dockerfile\.package):' || true)" \
    "ORT_LIB_LOCATION/ORT_DYLIB_PATH are set only by the two final images"
}

# _f11_env_writes <corpus>: "<path>:<line>: <name>=<value>" per ort-sys variable a line SETS (k=v, ${env:}, YAML/
# Python maps, environ[..], SetEnvironmentVariable, setx, Set-Item, legacy ENV/ARG); value lower-cased, "" unread.
_f11_env_writes() {
  awk -v N='(ort_lib_path|ort_lib_location|ort_dylib_path|ort_strategy|ort_skip_download|cargo_net_offline|ort_offline)' \
      -v Q="[\"']" -v V="^[^\"'[:space:]\`;),}|&<>]*" '
    BEGIN {
      KV = "(^|[^a-z0-9_])" N "[}]?[[:space:]]*:?="
      IX = Q N Q "[[:space:]]*[]][[:space:]]*="
      API = "(setenvironmentvariable|setdefault|putenv|setenv)[[:space:]]*[(][[:space:]]*" Q N Q "[[:space:]]*,"
      PRV = "(set-item|new-item)[[:space:]]([^|;]*[^$a-z0-9_{])?env:[\\\\/]?" N "([^a-z0-9_]|$)"
      SETX = "(^|[^a-z0-9_-])setx[[:space:]]+(/m[[:space:]]+)?" N "([[:space:]]|$)"
      MAP = "(^[[:space:]]*(-[[:space:]]+)?|[{,][[:space:]]*)" Q "?" N Q "?[[:space:]]*:([[:space:]]|$)"
      DKR = "^[[:space:]]*(env|arg)[[:space:]]+" N "([[:space:]]+|$)" }
    function emit(m, rest) {
      match(m, N); nm = substr(m, RSTART, RLENGTH)
      sub(/^[[:space:]]*(-value[[:space:]]+)?/, "", rest)
      if (substr(rest, 1, 1) ~ Q) rest = substr(rest, 2)
      match(rest, V); print p ":" ln ": " nm "=" substr(rest, 1, RLENGTH) }
    # One match() site per form: gawk recompiles a dynamic regex each time its site sees a different one.
    function hit(k, s) {
      return k == 1 ? match(s, KV) : k == 2 ? match(s, IX) : k == 3 ? match(s, API) : k == 4 ? match(s, PRV) \
        : k == 5 ? match(s, SETX) : k == 6 ? match(s, MAP) : match(s, DKR) }
    function each(k, s,   m) {
      while (hit(k, s)) { m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); if (s !~ /^[=~]/) emit(m, s) } }
    { p = substr($0, 1, index($0, ":") - 1); r = substr($0, index($0, ":") + 1)
      ln = substr(r, 1, index(r, ":") - 1); t = tolower(substr(r, index(r, ":") + 1))
      if (t !~ N) next
      each(1, t); each(2, t); each(3, t); each(4, t); each(5, t)
      if (p ~ /\.(ya?ml|py|json)$/) each(6, t)
      if (p ~ /(^|\/)Dockerfile[^\/]*$/) each(7, t) }' "$1" 2>/dev/null || true
}

# fix11_ort_cargo: ort's DEFAULT features include download-binaries, so every ort/ort-sys dependency (inline,
# a [..dependencies.X] table, dotted X.* keys, or renamed by package = "ort") must say default-features = false.
fix11_ort_cargo() {
  local hits
  hits="$(cd "${REPO_ROOT}" && find . \( -name .git -o -name external -o -name out -o -name target -o -name node_modules \) \
      -prune -o -type f -name Cargo.toml -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        awk -v f="${f#./}" -v Q="[\"']" -v O="[\"']ort(-sys)?[\"']" -v DF='default[-_]features[[:space:]]*=[[:space:]]*false' '
          function flush(n) {
            if (one != "" && isort && !df) print f ":" at ": [" one "] keeps the default features"
            for (n in dort) if (!(n in ddf)) print f ":" dat[n] ": " n ".* keeps the default features"
            split("", dort); split("", ddf); split("", dat); one = ""; isort = 0; df = 0 }
          { l = tolower($0) }
          l ~ /^[[:space:]]*#/ { next }
          /download-binaries/ { print f ":" FNR ": " $0; next }
          l ~ /^[[:space:]]*\[/ { flush(); h = l; sub(/#.*/, "", h); gsub("[[:space:]]|" Q, "", h); deps = (h ~ /dependencies\]$/)
            if (h ~ /dependencies\.[a-z0-9_-]+\]$/) { one = h; sub(/^.*dependencies\./, "", one); sub(/\]$/, "", one); isort = (one ~ /^ort(-sys)?$/); at = FNR }
            next }
          one != "" && l ~ ("^[[:space:]]*package[[:space:]]*=[[:space:]]*" O) { isort = 1 }
          one != "" && l ~ ("^[[:space:]]*" DF) { df = 1 }
          deps && (l ~ ("^[[:space:]]*" Q "?ort(-sys)?" Q "?[[:space:]]*=") || l ~ ("[{,][[:space:]]*package[[:space:]]*=[[:space:]]*" O)) && l !~ DF { print f ":" FNR ": " $0 }
          deps && l ~ /^[[:space:]]*[a-z0-9_-]+\.[a-z_-]+[[:space:]]*=/ { k = l; sub(/^[[:space:]]*/, "", k); n = substr(k, 1, index(k, ".") - 1)
            k = substr(k, index(k, ".") + 1); v = k; sub(/[[:space:]]*=.*/, "", k); sub(/^[^=]*=[[:space:]]*/, "", v)
            if (!(n in dat)) dat[n] = FNR
            if (n ~ /^ort(-sys)?$/ || (k == "package" && v ~ ("^" O))) dort[n] = 1
            if (k ~ /^default[-_]features$/ && v ~ /^false/) ddf[n] = 1 }
          END { flush() }' "${f}"
      done || true)"
  _f11_verdict "${hits}" "no Cargo.toml here enables ort's download-binaries (explicitly or by default features)"
}

# fix11_ort_consumer_config: OpenCV pre-sets HAVE_ONNXRUNTIME wherever it turns ORT on and has no silent
# WITH_ONNXRUNTIME=OFF; GenAI always gets ORT_HOME and never WinML's NuGet ORT.
fix11_ort_consumer_config() {
  local q="'"
  _f11_pair "every OpenCV configure that enables ORT pre-sets HAVE_ONNXRUNTIME (dnn's download branch)" \
    "-dwith_onnx(runtime)?(:bool)?=[\"${q}]?(on|1|true)([^a-z0-9_]|\$)" '-dhave_onnxruntime(:bool)?=(on|1|true)([^a-z0-9_]|$)'
  _f11_deny "OpenCV never falls back to building WITHOUT the chain ORT" \
    "-dwith_onnxruntime(:bool)?=[\"${q}]?(off|0|false)([^a-z0-9_]|\$)" '' '' '' \
    '^(linux/scripts/03-media/build/opencv/(build-opencv|opencv-ort)\.sh|windows/scripts/build/Build-OpencvFromSource\.ps1)$'
  _f11_require "windows/scripts/build/Build-OnnxGenaiFromSource.ps1" '-dort_home[:=]' 1+ \
    "Windows GenAI configures against ORT_HOME, never its NuGet fetch"
  _f11_deny "GenAI never turns on USE_WINML (it replaces ORT_HOME with a WinML NuGet ORT)" \
    'use_winml' '' '' '' '(Build-OnnxGenaiFromSource\.ps1|/onnxruntime/build/)'
  _f11_count genai-build "${F11_GENAI_BUILD}" '[[:space:]]build\.py([[:space:]]|$)'
  _f11_count genai-ort-home "${F11_GENAI_BUILD}" '--ort_home[[:space:]]'
}

# fix11_ort_genai_calls: every Linux GenAI build.py call passes --ort_home (counted by _f11_judge).
fix11_ort_genai_calls() {
  local nb="${_F11_N[genai-build]}" no="${_F11_N[genai-ort-home]}"
  if [ "${nb}" -gt 0 ] && [ "${no}" -ge "${nb}" ]; then
    pass "fix11: every Linux GenAI build.py call passes --ort_home (${no}/${nb})"
  else
    fail "fix11: ${F11_GENAI_BUILD}: ${nb} build.py call(s) but ${no} --ort_home -- GenAI would fetch ORT"
  fi
}

# fix11_ort_crate_env: G3 -- both final images point ort-sys at the chain, the paths they name are the
# ones the chain build installs, and both smokes assert it.
fix11_ort_crate_env() {
  local w="windows/Dockerfile" l="linux/Dockerfile.package" r
  r='(\$\{?onnx_root\}?|c:\\runtime\\lib\\onnxruntime-source)'
  _f11_require "${w}" "(^|[[:space:]])ort_lib_location=${r}\\\\lib([[:space:]\`]|\$)" 1 "${w} sets ORT_LIB_LOCATION to the chain lib dir"
  _f11_require "${w}" "(^|[[:space:]])ort_dylib_path=${r}\\\\bin\\\\onnxruntime\\.dll([[:space:]\`]|\$)" 1 "${w} sets ORT_DYLIB_PATH to the chain DLL"
  _f11_require "${w}" '(^|[[:space:]])ort_prefer_dynamic_link=(1|true)([[:space:]`]|$)' 1 "${w} sets ORT_PREFER_DYNAMIC_LINK=1"
  _f11_require "${w}" '(^|[[:space:]])ort_skip_download=(1|true)([[:space:]`]|$)' 1 "${w} sets ORT_SKIP_DOWNLOAD=1"
  _f11_require "windows/Dockerfile.media-merge-builder" 'onnx_root="c:\\runtime\\lib\\onnxruntime-source"' 1 "ONNX_ROOT is the chain install"
  _f11_require "windows/scripts/build/Build-OnnxFromSource.ps1" '\$ortinstalldir = "\$installdir\\lib\\onnxruntime-source"' 1 \
    "Build-OnnxFromSource.ps1 installs where ONNX_ROOT points"
  r='(\$\{onnxruntime_output_dir\}|/usr/local/lib/onnxruntime-cpu)'
  _f11_require "${l}" "^env ort_lib_location=${r}/lib\$" 1 "${l} sets ORT_LIB_LOCATION to the chain lib dir"
  _f11_require "${l}" "^env ort_dylib_path=${r}/lib/libonnxruntime\\.so\$" 1 "${l} sets ORT_DYLIB_PATH to the chain library"
  _f11_require "${l}" '^env ort_prefer_dynamic_link=(1|true)$' 1 "${l} sets ORT_PREFER_DYNAMIC_LINK=1"
  _f11_require "${l}" '^env ort_skip_download=(1|true)$' 1 "${l} sets ORT_SKIP_DOWNLOAD=1"
  _f11_require "${l}" '^arg onnxruntime_output_dir=/usr/local/lib/onnxruntime-cpu$' 1 "${l}'s ORT prefix is the chain CPU build"
  _f11_require "windows/scripts/build/Test-Container.ps1" 'get-ortcrateenvfinding -onnxroot \$env:onnx_root\)' 1 \
    "the Windows smoke asserts the ort crate env"
  _f11_require "linux/scripts/06-packaging/smoke-runtime-image.sh" '^_consumer_contract_rows=.*[" ]ort-crate-env[" ]' 1 \
    "the Linux consumer contract asserts the ort crate env"
}

# _f11_instructions <dockerfile>...: "<dockerfile><TAB><instruction>" per instruction, lower-cased,
# continuations joined (backslash, or backtick under a Windows escape directive).
_f11_instructions() {
  (cd "${REPO_ROOT}" && awk 'FNR == 1 { flush(); esc = ($0 ~ /^#[[:space:]]*escape=`/) ? "`" : "\\\\" }
    function flush() { if (buf ~ /[^[:space:]]/) print df "\t" tolower(buf); buf = ""; df = FILENAME }
    { sub(/\r$/, "") } /^[[:space:]]*#/ { next }
    { l = $0; cont = (l ~ (esc "[[:space:]]*$")); sub(esc "[[:space:]]*$", "", l); buf = buf " " l }
    !cont { flush() }
    END { flush() }' "$@" 2>/dev/null) || true
}

# _f11_unmounted_runs: every consumer RUN, on either lane, that does not bind-mount its G2 helper.
_f11_unmounted_runs() {
  local dfs=() df runs
  for df in "${REPO_ROOT}"/windows/Dockerfile* "${REPO_ROOT}"/linux/Dockerfile.*; do
    if [ -f "${df}" ]; then dfs+=("${df#"${REPO_ROOT}/"}"); fi
  done
  [ "${#dfs[@]}" -gt 0 ] || return 0
  printf -v runs '%s|' "${F11_LINUX_G2_RUNS[@]}"
  _f11_instructions "${dfs[@]}" | awk -v wm="source=${F11_WIN_G2_MODULE,,}," \
      -v lm="source=${F11_LINUX_G2_HELPER}," -v runs="${runs}" '
    { i = index($0, "\t"); df = substr($0, 1, i - 1); $0 = substr($0, i + 1) }
    $0 !~ /^[[:space:]]*run / { next }
    df ~ /^windows/ && $0 ~ /source=windows\/scripts\/build\/build-(opencv|onnxgenai|ffmpeg|gstreamer|ortamdgpuep)fromsource\.ps1/ && !index($0, wm) {
      print df ": a consumer RUN without " wm }
    df ~ /^linux/ { n = split(runs, r, "|"); for (i = 1; i <= n; i++) if (r[i] != "" && index($0, r[i]) && !index($0, lm)) print df ": the " r[i] " RUN without " lm }'
}

# fix11_ort_gate_wiring: G2 is called by every consumer and mounted per file into its RUN, never into a
# shared closure; G1 runs in both smokes; the invariant (G5) is written down.
fix11_ort_gate_wiring() {
  local row f call mod="${F11_WIN_G2_MODULE##*/}" hl="${F11_LINUX_G2_HELPER##*/}" lmod
  lmod="${mod,,}"
  for row in "${F11_GATE_CALLS[@]}"; do
    f="${row%%|*}"; call="${row#*|}"; call="${call,,}"
    _f11_require "${f}" "(^|[^a-z0-9_-])${call}([^a-z0-9_-]|\$)" 1 "${f##*/} calls ${row#*|} exactly once" \
      "function[[:space:]]+${call}([^a-z0-9_-]|\$)|(^|[[:space:]])${call}\\(\\)"
  done
  _f11_deny "${mod} reaches a Windows Dockerfile only as per-file bind mounts (no COPY, no directory mount)" \
    "${lmod}" '' '' "--mount=type=bind,source=${F11_WIN_G2_MODULE,,}," '^windows/Dockerfile'
  _f11_deny "${hl} reaches a Linux Dockerfile only as per-file bind mounts (no COPY, no directory mount)" \
    "${hl}" '' '' "--mount=type=bind,source=${F11_LINUX_G2_HELPER}," '^linux/Dockerfile'
  _f11_deny "${mod} is not pulled in by WindowsSourceBuild.Common or Build-MediaCoreAll (both re-key the ONNX branch)" \
    "${lmod%.psm1}" '' '' '' '^windows/scripts/(modules/WindowsSourceBuild\.Common\.psm1|build/Build-MediaCoreAll\.ps1)$'
  _f11_verdict "$(_f11_unmounted_runs)" "every consumer RUN mounts its G2 helper"
  _f11_require "windows/scripts/build/Test-Container.ps1" 'windowsortprovenance\.common' 1+ "the Windows smoke imports the ORT census"
  _f11_require "windows/scripts/build/Test-Container.ps1" '(get-ortcensusfinding|invoke-ort(image)?census|test-ortprovenancetree)' 1+ \
    "the Windows smoke runs the ORT census (G1)" 'function[[:space:]]'
  _f11_require '^linux/(scripts/06-packaging/smoke-runtime-image\.sh|Dockerfile\.package)$' \
    '^[[:space:]]+check_ort_census[[:space:]]|check-ort-provenance\.sh[[:space:]]+[^[:space:]]' 1+ \
    "the Linux runtime smoke or the wrapper-smoke stage runs the ORT census (G1)"
  if grep -qxF -e '### ONNX Runtime has exactly one source: the chain (owner rule 2026-09-23)' "${REPO_ROOT}/docs/windows-build-invariants.md" 2>/dev/null; then
    pass "fix11: docs/windows-build-invariants.md carries the ORT single-source invariant (G5)"
  else
    fail "fix11: docs/windows-build-invariants.md lost '### ONNX Runtime has exactly one source: the chain (owner rule 2026-09-23)'"
  fi
}

# fix11_ort_census_roots: the census tells a chain build apart by the source root baked into its bytes,
# so each lane's census must name the root its ORT build really uses.
fix11_ort_census_roots() {
  local win lin lc
  win="$(sed -n "/^[[:space:]]*\[string\]\\\$SourceDir = '\([^']*\)'.*/{s//\1/p;q;}" "${REPO_ROOT}/windows/scripts/build/Build-OnnxFromSource.ps1" 2>/dev/null)"
  lin="$(sed -n '/^[[:space:]]*ORT_SRC_DIR="\${ORT_SRC_DIR:-\([^}]*\)}".*/{s//\1/p;q;}' "${REPO_ROOT}/linux/scripts/03-media/build/onnxruntime/build/lib/common.sh" 2>/dev/null)"
  if [ -n "${win}" ] && grep -qiF -e "${win}" "${REPO_ROOT}/${F11_WIN_CENSUS_MODULE}" 2>/dev/null; then
    pass "fix11: the Windows census fingerprints the ORT source root ${win}"
  else
    fail "fix11: Build-OnnxFromSource.ps1's SourceDir ('${win}') is not the root ${F11_WIN_CENSUS_MODULE} fingerprints"
  fi
  lc="$(cat "${REPO_ROOT}/linux/scripts/06-packaging/check-ort-provenance.sh" "${REPO_ROOT}/${F11_LINUX_G2_HELPER}" 2>/dev/null || true)"
  if [ -n "${lin}" ] && [ "${lc}" != "${lc#*"${lin}"}" ]; then
    pass "fix11: the Linux census fingerprints the ORT source root ${lin}"
  else
    fail "fix11: lib/common.sh's ORT_SRC_DIR ('${lin}') is not the root the Linux census fingerprints"
  fi
}

fix11_ort_single_source_2026_09() {
  echo "--- Fix 11: ONNX Runtime has exactly one source, the chain (owner rule 2026-09-23) ---"
  local corpus
  corpus="$(mktemp)"
  _f11_corpus "${corpus}"
  if [ -s "${corpus}" ]; then
    _F11_RULES=()
    declare -gA _F11_N=()
    fix11_ort_fetch_denylist "${corpus}"
    fix11_ort_consumer_config
    fix11_ort_crate_env
    fix11_ort_gate_wiring
    _f11_judge "${corpus}"
    fix11_ort_genai_calls
  else
    fail "fix11: the scan set is empty, so nothing was checked"
  fi
  fix11_ort_cargo
  fix11_ort_census_roots
  rm -f "${corpus}" "${corpus}.rules" "${corpus}.verdicts"
}

echo "=== Critical Fixes: host tree checks ==="
echo ""

FIX_FUNCS=(fix5_gst_geometry_include fix6_native_gcc_system_paths fix7_hardening_2026_07 fix8_push_retry_2026_07 fix9_riscv_isaspec_and_noise_2026_07 fix10_libstdcxx_nostdinc_2026_08 fix11_ort_single_source_2026_09)
for _fix_fn in "${FIX_FUNCS[@]}"; do
  "${_fix_fn}"
  echo ""
done

smoke_summary
