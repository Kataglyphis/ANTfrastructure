#!/usr/bin/env bash
# Characterisation of verify-critical-fixes.sh, the host half of the battery. The
# gate is a wall of greps over the repo tree, so a suite has to give it a tree of
# its own and knock out one guarded line at a time. The /opt-probing half moved to
# 06-packaging/smoke-critical-fixes.sh, which is why this can be complete at all.
# docs/cross-build-verification.md#the-in-image-half-of-critical-fixes
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../verify-critical-fixes.sh"
IMAGE_SMOKE="${TESTS_DIR}/../06-packaging/smoke-critical-fixes.sh"
PKG="${TESTS_DIR}/../06-packaging"
CSB="${TESTS_DIR}/../01-core/cross-stage-build.sh"
PAYLOADS="${TESTS_DIR}/../06-packaging/copy-media-payloads.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

_classifier="$(t_fn_src "${CSB}" _cross_stage_push_error_is_transient)" || exit 1

_write() { install -D -m 0644 /dev/stdin "$1"; }

# _tree — a throwaway repo root holding the gate at its real depth plus the
# minimal healthy version of every file it greps. The transient-push classifier
# is the REAL one (the gate extracts and RUNS it), so the fixture cannot drift.
_tree() {
  local d
  d="$(mktemp -d "${_work}/tree.XXXXXX")"
  install -D -m 0755 "${GATE}" "${d}/linux/scripts/verify-critical-fixes.sh"
  install -D -m 0644 "${PKG}/smoke-common.sh" "${d}/linux/scripts/06-packaging/smoke-common.sh"

  _write "${d}/linux/scripts/03-media/build/gstreamer/common/patch-gstreamer-sources.sh" <<'F'
sed -i 's|#include <opencv2/core.hpp>|&\n#include <opencv2/geometry.hpp>|' gstsegmentation.cpp
F
  _write "${d}/linux/scripts/06-packaging/setup-torch-venv.sh" <<'F'
export CFLAGS="-idirafter /usr/include"
export CXXFLAGS="-idirafter /usr/include"
touch /opt/venv/.torch-missing
F
  _write "${d}/linux/scripts/06-packaging/swap-native-gcc.sh" <<'F'
printf 'CFLAGS="-idirafter /usr/include"\n' > /etc/profile.d/00-native-gcc.sh
note "benign: invalid -march= skew"
F
  _write "${d}/linux/scripts/03-media/runtime/install-deps.sh" <<'F'
  libjpeg-dev
F
  _write "${d}/linux/scripts/03-media/runtime/repair-wheels.sh" <<'F'
note "benign: too-recent versioned symbols"
F
  {
    printf 'cache_args+=(--cache-to type=local,dest="${dir}")\n'
    printf 'PUSH_MAX_ATTEMPTS="${PUSH_MAX_ATTEMPTS:-4}"\n'
    printf 'stage_log="${dir}/${CROSS_RUN_ID}.run"\n'
    printf '%s\n' "${_classifier}"
  } | _write "${d}/linux/scripts/01-core/cross-stage-build.sh"
  _write "${d}/linux/scripts/01-core/compiler-cache.sh" <<'F'
_sc_launcher="sccache"
[ -x "${dir}/sccache-launcher.sh" ] && _sc_launcher="${dir}/sccache-launcher.sh"
F
  _write "${d}/linux/scripts/01-core/runtime-build-fns.sh" <<'F'
runtime_push_tag() {
  _runtime_push_attempt "$1"
}
_runtime_push_attempt() {
  # retry policy lives in runtime_push_tag; this only reports the push rc
  run "${NERDCTL_BIN:-nerdctl}" push "${tag}"
}
F
  _write "${d}/linux/scripts/build-runtime-manifest.sh" <<'F'
retry "${PUSH_MAX_ATTEMPTS:-4}" "manifest push ${IMAGE_NAME}" run nerdctl manifest push
F
  _write "${d}/linux/scripts/01-core/base-image.sh" <<'F'
printf 'APT::Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/80-retries
F
  _write "${d}/linux/scripts/01-core/versions.env" <<'F'
UBUNTU_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
F
  _write "${d}/linux/scripts/02-toolchain/build-gcc.sh" <<'F'
    riscv64-*)
      cfg+=("--with-isa-spec=${RISCV_GCC_ISA_SPEC-20191213}")
      ;;
if ! grep -q -- '-nostdinc++' src/c++23/Makefile.in; then
  sed -i 's|@AM_CXXFLAGS@|-std=gnu++23 -nostdinc++|' src/c++23/Makefile.in \
    || die "AM_CXXFLAGS layout changed"
fi
F
  _write "${d}/linux/Dockerfile.base" <<'F'
FROM ubuntu:${UBUNTU_VERSION}@${UBUNTU_DIGEST}
RUN --mount=type=bind,source=linux/scripts/01-core,target=/opt/scripts/core true
F
  _write "${d}/linux/Dockerfile.torch" <<'F'
RUN chown -R kataglyphis:kataglyphis ${WORKDIR}
F
  _tree_ort_windows "${d}"
  _tree_ort_linux "${d}"
  printf '%s' "${d}"
}

# _tree_ort_windows <root> -- fix11's Windows inputs, healthy: G2/G3/G1 wired, nothing fetched.
_tree_ort_windows() {
  local d="$1" s="$1/windows/scripts/build" f
  _write "${d}/windows/Dockerfile" <<'F'
# escape=`
ENV ORT_LIB_LOCATION=$ONNX_ROOT\lib `
    ORT_PREFER_DYNAMIC_LINK=1 `
    ORT_SKIP_DOWNLOAD=1 `
    ORT_DYLIB_PATH=$ONNX_ROOT\bin\onnxruntime.dll
F
  _write "${d}/windows/Dockerfile.media-merge-builder" <<'F'
# escape=`
ENV ONNX_ROOT="C:\runtime\lib\onnxruntime-source" `
    PYTHON_WHEELS="C:\runtime\wheels"
RUN --mount=type=bind,source=windows/scripts/build/Build-GstreamerFromSource.ps1,target=C:\bkmnt\Build-GstreamerFromSource.ps1 `
    --mount=type=bind,source=windows/scripts/modules/WindowsOrtProvenance.Build.psm1,target=C:\bkmnt\ortmods\WindowsOrtProvenance.Build.psm1 `
    & 'C:\bkmnt\Build-GstreamerFromSource.ps1'
F
  _write "${d}/windows/Dockerfile.media-builder" <<'F'
# escape=`
FROM base AS buildmods
COPY windows\scripts\modules\WindowsSourceBuild.Common.psm1 `
     C:\bkmods\
RUN --mount=type=bind,source=windows/scripts/build/Build-OpencvFromSource.ps1,target=C:\bkmnt\Build-OpencvFromSource.ps1 `
    --mount=type=bind,source=windows/scripts/modules/WindowsOrtProvenance.Build.psm1,target=C:\bkmnt\ortmods\WindowsOrtProvenance.Build.psm1 `
    & 'C:\bkmnt\Build-MediaCoreAll.ps1' -ResumeFrom 'OpenCV'
F
  _write "${s}/Build-OnnxFromSource.ps1" <<'F'
    [string]$SourceDir = 'C:\temp\onnx-src',
$ortInstallDir = "$InstallDir\lib\onnxruntime-source"
F
  _write "${s}/Build-OpencvFromSource.ps1" <<'F'
    '-DWITH_ONNXRUNTIME=ON',
    '-DHAVE_ONNXRUNTIME=ON'
function Get-OpencvOrtConfigureFinding { param($Log) }
$cfg = @(Get-OpencvOrtConfigureFinding -Log $log)
Assert-ChainOrtOnly -Consumer 'opencv' -BuildDir $buildDir
F
  _write "${s}/Build-OnnxGenaiFromSource.ps1" <<'F'
    "-DORT_HOME:PATH=$shim"
$cfg = @(Get-GenaiOrtConfigureFinding -ConfigureLog $log)
Assert-ChainOrtOnly -Consumer 'genai' -BuildDir $buildDir
F
  for f in Ffmpeg Gstreamer OrtAmdgpuEp; do
    printf 'Assert-ChainOrtOnly -Consumer %s\n' "${f}" | _write "${s}/Build-${f}FromSource.ps1"
  done
  printf '%s\n' "Import-Module 'WindowsSourceBuild.Common.psm1'" | _write "${s}/Build-MediaCoreAll.ps1"
  _write "${s}/Test-Container.ps1" <<'F'
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsOrtProvenance.Common.psm1') -Force
$ortCensus = @(Invoke-OrtImageCensus -Root 'C:\')
$ortCrateFindings = @(Get-OrtCrateEnvFinding -OnnxRoot $env:ONNX_ROOT)
F
  printf '%s\n' "Import-Module 'WindowsScripts.Shared.psm1'" | _write "${d}/windows/scripts/modules/WindowsSourceBuild.Common.psm1"
  _write "${d}/windows/scripts/modules/WindowsOrtProvenance.Common.psm1" <<'F'
function Get-OrtChainSourceRoot { return @('C:\temp\onnx-src') }
$inboxFile = @(foreach ($d in 'System32', 'SysWOW64') { "$winDir\$d\onnxruntime.dll"; "$winDir\$d\Windows.AI.MachineLearning.dll" })
F
  _write "${d}/windows/scripts/modules/WindowsOrtProvenance.Build.psm1" <<'F'
function Assert-ChainOrtOnly { param($Consumer, $TreeRoot) }
F
  _write "${d}/windows/scripts/modules/WindowsOnnx.Common.psm1" <<'F'
$script:OrtNuGetIdPattern = '(?i)onnxruntime|^Microsoft\.(Windows\.)?AI\.MachineLearning(\.|$)'
function Install-OptionalNuGetPackage {
    param([string]$PackageId)
    if ($PackageId -match $script:OrtNuGetIdPattern) {
        throw "$PackageId is an ONNX Runtime package and is refused"
    }
    nuget install $PackageId
}
Export-ModuleMember -Function @('Install-OptionalNuGetPackage')
F
}

# _tree_ort_linux <root> -- fix11's Linux inputs, healthy, plus the G5 invariant heading.
_tree_ort_linux() {
  local d="$1" m="$1/linux/scripts/03-media" r
  _write "${d}/linux/Dockerfile.package" <<'F'
ARG ONNXRUNTIME_OUTPUT_DIR=/usr/local/lib/onnxruntime-cpu
ENV ORT_LIB_LOCATION=${ONNXRUNTIME_OUTPUT_DIR}/lib
ENV ORT_PREFER_DYNAMIC_LINK=1
ENV ORT_SKIP_DOWNLOAD=1
ENV ORT_DYLIB_PATH=${ONNXRUNTIME_OUTPUT_DIR}/lib/libonnxruntime.so
F
  for r in build/opencv/build-opencv.sh build/ffmpeg/build-ffmpeg.sh build/gstreamer/common/build-gstreamer-stage.sh \
           "verify-genai-ort.sh --src-dir /opt/onnxruntime-genai"; do
    printf 'RUN --mount=type=bind,source=linux/scripts/03-media/ort-provenance.sh,target=/opt/scripts/03-media/ort-provenance.sh,readonly \\\n    bash /opt/scripts/03-media/%s\n' "${r}"
  done | _write "${d}/linux/Dockerfile.media"
  printf 'ORT_CHAIN_SOURCE_ROOTS=(/opt/onnxruntime)\nort_assert_chain_only() { :; }\n' | _write "${m}/ort-provenance.sh"
  printf '  ort_assert_chain_only genai --stamp "${out}/ort-provenance/genai.json" --tree "${src}" "${g2[@]}"\n' \
    | _write "${m}/verify-genai-ort.sh"
  printf '        "-DWITH_ONNXRUNTIME=ON"\n        "-DHAVE_ONNXRUNTIME=1"\n        "-DDOWNLOAD_ONNXRUNTIME=OFF"\n' \
    | _write "${m}/build/opencv/opencv-ort.sh"
  _write "${m}/build/opencv/build-opencv.sh" <<'F'
opencv_ort_assert_configure "${build_dir}" "${compat}" "${ver}" || die "configure gate"
ort_assert_chain_only opencv "${build_dir}"
opencv_ort_assert_installed "${OPENCV_PREFIX}" || die "install gate"
F
  printf 'ort_assert_chain_only ffmpeg "${build_dir}"\n    ort_findings="$(ffmpeg_ort_link_findings ffbuild/config.mak "${_FFMPEG_ONNX_ROOT:-}")"\n' \
    | _write "${m}/build/ffmpeg/build-ffmpeg.sh"
  printf 'ffmpeg_ort_link_findings() {\n  :\n}\n' | _write "${m}/build/ffmpeg/ffmpeg-dnn-backends.sh"
  printf '  findings="$(gst_onnx_ort_findings builddir/build.ninja)"\nort_assert_chain_only gstreamer builddir\n' \
    | _write "${m}/build/gstreamer/common/build-gstreamer-monorepo.sh"
  _write "${m}/build/onnxruntime/build/60-build-genai.sh" <<'F'
  retry 3 10 "GenAI GPU build" "${HOST_PYTHON}" build.py \
    --ort_home "${ORT_HOME}" \
  retry 3 10 "GenAI CPU build" "${HOST_PYTHON}" build.py \
    --ort_home "${ORT_HOME}"
F
  printf '  ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"\n' | _write "${m}/build/onnxruntime/build/lib/common.sh"
  _write "${m}/runtime/validate-media-runtime.sh" <<'F'
  ort_is_denied_soname "${so_name}" && return 2
  ort_apt_plan_gate "${UNIQ_PKGS[@]}" || exit 1
ort_dpkg_gate || exit 1
F
  printf 'libonnxruntime.so*\tsource-built\nlibtvm.so.*\tsource-built\n' | _write "${m}/runtime/so-package-map.txt"
  printf 'ort_census_verdicts "$@"\n' | _write "${d}/linux/scripts/06-packaging/check-ort-provenance.sh"
  printf '_CONSUMER_CONTRACT_ROWS="ccache-dir web-lane-tools ort-crate-env"\n    check_ort_census "${image_tag}" "${target_arch}"\n' \
    | _write "${d}/linux/scripts/06-packaging/smoke-runtime-image.sh"
  printf '### ONNX Runtime has exactly one source: the chain (owner rule 2026-09-23)\n' | _write "${d}/docs/windows-build-invariants.md"
  printf 'env:\n  ORT_SKIP_DOWNLOAD: "1"\n' | _write "${d}/.github/workflows/ci.yml"
}

_gate() { bash "$1/linux/scripts/verify-critical-fixes.sh"; }

# The gate minus its driver: its F11_* tables and every function, extracted with t_fn_src, so a row runs only
# the fix it knocks out (a whole gate per row made this suite 45-59 s on CI). The Cargo case runs the real gate.
_FIX_FUNCS=()
read -r -a _FIX_FUNCS <<< "$(sed -n 's/^FIX_FUNCS=(\(.*\))$/\1/p' "${GATE}")"
_gate_lib="set -euo pipefail"$'\n'"source '${PKG}/smoke-common.sh'"$'\n'"$(awk '/^F11_[A-Z0-9_]+=\($/ { a = 1 }
  a || /^F11_[A-Z0-9_]+=/ { print } /^\)$/ { a = 0 }' "${GATE}")"
for _fn in $(sed -n 's/^\([a-z_][a-z0-9_]*\)() {$/\1/p' "${GATE}"); do
  _src="$(t_fn_src "${GATE}" "${_fn}")" || exit 1
  _gate_lib+=$'\n'"${_src}"
done
declare -A _FN_OF=()
for _fn in "${_FIX_FUNCS[@]}"; do _FN_OF["${_fn%%_*}"]="${_fn}"; done
# _run_fix <tree> <fix function>: that one fix over <tree>, ending in the gate's own summary and exit code.
_run_fix() { REPO_ROOT="$1" bash -c "${_gate_lib}"$'\n'"$2"$'\n''smoke_summary'; }

# _red <fixN> <relpath> <sed expr> <expected message> — one guarded line knocked out of a copy of the
# healthy fixture; the finding has to be a FAIL line of that fix.
_rows=0
_red() {
  local d out rc=0 line fails=""
  d="${_work}/row$((_rows += 1))"
  cp -a "${_healthy}" "${d}"
  sed -i -e "$3" "${d}/$2"
  out="$(_run_fix "${d}" "${_FN_OF[$1]}" 2>&1)" || rc=$?
  while IFS= read -r line; do
    case "${line}" in *FAIL*) fails+="${line}"$'\n' ;; esac
  done <<< "${out}"
  t_assert_eq "1" "${rc}" "knocking out $2 must fail $1"
  t_assert_contains "${fails}" "$4" "wrong finding for $2 / $3"
}

t_case "a healthy tree passes — without this the reds below prove nothing"
_healthy="$(_tree)"
_healthy_rc=0
_healthy_out="$(_gate "${_healthy}" 2>&1)" || _healthy_rc=$?
t_assert_eq "0" "${_healthy_rc}"
t_assert_contains "${_healthy_out}" "=== Results: 0 failure(s) ==="
t_assert_contains "${_healthy_out}" "Critical Fixes: host tree checks"

t_case "every fix the gate defines is in FIX_FUNCS, and the extracted fixes print exactly what the gate prints"
t_assert_eq "$(sed -n 's/^fix\([0-9]*\)_.*() {$/\1/p' "${GATE}" | LC_ALL=C sort -u | tr '\n' ' ')" \
  "$(printf '%s\n' "${!_FN_OF[@]}" | sed 's/^fix//' | LC_ALL=C sort -u | tr '\n' ' ')" "a fix left out of FIX_FUNCS never runs"
_each=""
for _fn in "${_FIX_FUNCS[@]}"; do
  _each+="$(REPO_ROOT="${_healthy}" bash -c "${_gate_lib}"$'\n'"${_fn}" 2>&1)"$'\n\n'
done
t_assert_eq "$(printf '%s\n' "${_healthy_out}" | sed '1,2d;$d')" "${_each%$'\n\n'}" \
  "the fixes run one at a time must print what the gate prints, or the rows below test something else"

t_case "the /opt-probing half is GONE from the host gate"
# It skipped on every host run it ever had, and fix4 was a tautology there
# (host cc is the host arch). Its real verdicts live in smoke-critical-fixes.sh.
for _moved in "Fix 1:" "Fix 2:" "Fix 3:" "Fix 4:"; do
  case "${_healthy_out}" in
    *"${_moved}"*) t_assert_eq "moved" "still here" "${_moved} must not run on the host" ;;
    *)             t_assert_eq "moved" "moved" ;;
  esac
done

# One table, not a wall of near-identical calls: at 29 rows the call shape is
# itself a clone family, and the dupes gate reads it as a copy.
# @LHS@ is the third fixture trap on GH5's list — spelled out, the row would BE a
# bare launcher export and the real gate's repo-wide scan would fail on the suite.
_bare_export_lhs='CMAKE_C_COMPILER_LAUNCHER='
_group=""
while IFS="$(printf '\t')" read -r _g _f _e _m; do
  [ -n "${_g}" ] || continue
  if [ "${_g}" != "${_group}" ]; then
    t_case "${_g}"
    _group="${_g}"
  fi
  _red "${_g%% *}" "${_f}" "${_e//@LHS@/${_bare_export_lhs}}" "${_m}"
done <<'ROWS'
fix5 — the geometry.hpp patch	linux/scripts/03-media/build/gstreamer/common/patch-gstreamer-sources.sh	s|geometry.hpp|core.hpp|	missing geometry.hpp reference
fix6 — the native-GCC system paths and the numpy seeding ban	linux/scripts/06-packaging/setup-torch-venv.sh	s|-idirafter /usr/include||g	lost the -idirafter CXXFLAGS injection
fix6 — the native-GCC system paths and the numpy seeding ban	linux/scripts/06-packaging/swap-native-gcc.sh	s|-idirafter /usr/include||	lost the -idirafter profile.d injection
fix6 — the native-GCC system paths and the numpy seeding ban	linux/scripts/03-media/runtime/install-deps.sh	s|libjpeg-dev|libjpeg62|	no longer installs libjpeg-dev
fix6 — the native-GCC system paths and the numpy seeding ban	linux/scripts/06-packaging/setup-torch-venv.sh	1i for pkg in numpy pillow; do :; done	re-seeds apt numpy into the venv
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/scripts/01-core/cross-stage-build.sh	s|type=local,dest="${dir}"|type=registry,ref=${tag}-buildcache|	reverted to the self-defeating registry -buildcache
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/scripts/01-core/compiler-cache.sh	1i RUSTC_WRAPPER="${_sc_launcher:-}"	can leave a launcher EMPTY
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/scripts/01-core/compiler-cache.sh	s|sccache-launcher.sh|sccache|g	no longer resolves a guarded launcher
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/scripts/01-core/compiler-cache.sh	s|^_sc_launcher="sccache"$|@LHS@"sccache"|	bare sccache launcher export found
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/Dockerfile.base	s|^FROM ubuntu:.*|FROM ubuntu:${UBUNTU_VERSION}|	ubuntu base is no longer digest-pinned
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/scripts/01-core/versions.env	s|^UBUNTU_DIGEST=sha256:|UBUNTU_DIGEST=|	ubuntu base is no longer digest-pinned
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/Dockerfile.torch	s|chown -R kataglyphis:kataglyphis|chown -R root:root|	no longer chowns WORKDIR
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/scripts/01-core/base-image.sh	s|apt.conf.d/80-retries|apt.conf.d/99-local|	lost the image-wide apt retry config
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/Dockerfile.base	s|source=linux/scripts/01-core,target=|source=linux/scripts,target=|	re-introduced a whole-tree scripts bind mount
fix7 — cache shape, the always-sccache decision, base pin, non-root, apt retry, mount scope	linux/Dockerfile.torch	1i RUN bash /opt/scripts/06-packaging/smoke-vulkan.sh	no full Vulkan SDK here
fix8 — push retry, the transient classifier itself, and per-run stage logs	linux/scripts/01-core/cross-stage-build.sh	s|PUSH_MAX_ATTEMPTS|PUSH_ATTEMPTS|g	lost the transient push-retry
fix8 — push retry, the transient classifier itself, and per-run stage logs	linux/scripts/01-core/runtime-build-fns.sh	s|# retry policy lives in runtime_push_tag.*|# reports the push rc|	has a bare (unretried) image push
fix8 — push retry, the transient classifier itself, and per-run stage logs	linux/scripts/build-runtime-manifest.sh	s|^retry |run |	manifest push is not retried
fix8 — push retry, the transient classifier itself, and per-run stage logs	linux/scripts/01-core/cross-stage-build.sh	s|^_cross_stage_push_error_is_transient() {|_renamed_classifier() {|	could not extract _cross_stage_push_error_is_transient
fix8 — push retry, the transient classifier itself, and per-run stage logs	linux/scripts/01-core/cross-stage-build.sh	s|'use of closed network connection.*|'NEVER_MATCHES_ANYTHING'|	no longer flags network drops as transient
fix8 — push retry, the transient classifier itself, and per-run stage logs	linux/scripts/01-core/cross-stage-build.sh	s|'use of closed network connection.*|'.'|	wrongly treats a build error as transient
fix8 — push retry, the transient classifier itself, and per-run stage logs	linux/scripts/01-core/cross-stage-build.sh	s|${CROSS_RUN_ID}|run|	lost per-run log truncation
fix9 — the riscv64 ISA-spec pin, the torch-less sentinel, both benign-noise classifiers	linux/scripts/02-toolchain/build-gcc.sh	s|--with-isa-spec=|--with-arch=|	lost the riscv64 ISA-spec pin
fix9 — the riscv64 ISA-spec pin, the torch-less sentinel, both benign-noise classifiers	linux/scripts/06-packaging/setup-torch-venv.sh	s|.torch-missing|.torch-absent|	lost the torch-less sentinel
fix9 — the riscv64 ISA-spec pin, the torch-less sentinel, both benign-noise classifiers	linux/scripts/03-media/runtime/repair-wheels.sh	s|too-recent versioned symbols|glibc mismatch|	lost the benign-auditwheel classifier
fix9 — the riscv64 ISA-spec pin, the torch-less sentinel, both benign-noise classifiers	linux/scripts/06-packaging/swap-native-gcc.sh	s|invalid -march=|bad march|	lost the benign -march classifier
fix10 — the PR100017 c++23 -nostdinc++ patch, its loud die and its self-retiring guard	linux/scripts/02-toolchain/build-gcc.sh	s|-std=gnu++23 -nostdinc++|-std=gnu++23|	LOST the PR100017 -nostdinc++ patch block
fix10 — the PR100017 c++23 -nostdinc++ patch, its loud die and its self-retiring guard	linux/scripts/02-toolchain/build-gcc.sh	s|AM_CXXFLAGS layout changed|patch failed|	lost its loud-failure die
fix10 — the PR100017 c++23 -nostdinc++ patch, its loud die and its self-retiring guard	linux/scripts/02-toolchain/build-gcc.sh	s|if ! grep -q -- '-nostdinc++' src/c++23/Makefile.in; then|if true; then|	lost its idempotence gate
ROWS

t_case "fix11 — ORT has one source: the denylist, the G1/G2/G3 wiring, the census roots, the invariant"
while IFS="$(printf '\t')" read -r _f _e _m; do
  [ -n "${_f}" ] || continue
  _red fix11 "${_f}" "${_e}" "${_m}"
done <<'ROWS11'
linux/scripts/03-media/build/opencv/opencv-ort.sh	/HAVE_ONNXRUNTIME=1/d	pre-sets HAVE_ONNXRUNTIME
linux/scripts/03-media/build/opencv/opencv-ort.sh	s|DOWNLOAD_ONNXRUNTIME=OFF|DOWNLOAD_ONNXRUNTIME=ON|	no OpenCV DOWNLOAD_ONNXRUNTIME
linux/scripts/03-media/build/opencv/build-opencv.sh	1i cmake_opts+=("-DWITH_ONNXRUNTIME=OFF")	never falls back to building WITHOUT
windows/scripts/build/Build-OpencvFromSource.ps1	1i $env:ORT_LIB_LOCATION = 'C:\onnxruntime\lib'	set only by the two final images
windows/scripts/build/Build-OpencvFromSource.ps1	1i & uv pip install onnxruntime-directml==1.24.4	no pip/uv install of an onnxruntime
windows/scripts/build/Build-OnnxGenaiFromSource.ps1	/-DORT_HOME/d	Windows GenAI configures against ORT_HOME
windows/scripts/build/Build-OnnxGenaiFromSource.ps1	1i "-DUSE_WINML=ON"	never turns on USE_WINML
linux/scripts/03-media/build/onnxruntime/build/60-build-genai.sh	0,/--ort_home/{/--ort_home/d}	build.py call(s) but 1 --ort_home
windows/scripts/build/Build-FfmpegFromSource.ps1	1i Install-OptionalNuGetPackage -PackageId 'Microsoft.ML.OnnxRuntime.DirectML' -Version 1.24.4	no Microsoft.ML.OnnxRuntime
windows/scripts/modules/WindowsOnnx.Common.psm1	/throw/d	lost the ORT refusal
windows/scripts/build/Build-OpencvFromSource.ps1	$a Copy-Item "$env:ONNX_ROOT\\bin\\onnxruntime.dll" "$env:windir\\System32\\" -Force	nothing deletes or patches an in-box ORT
windows/Dockerfile	$a RUN icacls C:/Windows/System32/Windows.AI.MachineLearning.dll /grant Administrators:F	nothing deletes or patches an in-box ORT
linux/scripts/01-core/versions.env	$a X_URL=https://files.pythonhosted.org/packages/d7/a4/onnxruntime_ep_webgpu-0.4.0-py3-none-win_amd64.whl	no ORT binary URL
linux/scripts/01-core/versions.env	$a ORT_LIB_PATH=/root/.cache/ort.pyke.io	nothing re-arms the ort crate download
linux/scripts/01-core/versions.env	$a CARGO_NET_OFFLINE=false	nothing re-arms the ort crate download
linux/scripts/03-media/runtime/install-deps.sh	$a apt-get install -y libonnxruntime1.23	no apt libonnxruntime
linux/scripts/03-media/runtime/install-deps.sh	s|^  libjpeg-dev$|apt-get install -y --no-install-recommends \\\n  libjpeg-dev \\\n  libonnxruntime-dev \\\n  libpng-dev|	no apt libonnxruntime
linux/scripts/03-media/runtime/install-deps.sh	s|^  libjpeg-dev$|  libjpeg-dev python3-onnxruntime\\|	no apt libonnxruntime
linux/scripts/03-media/runtime/install-deps.sh	$a PKGS+=(libonnxruntime1.23)	no apt libonnxruntime
linux/scripts/01-core/versions.env	$a ORT_SKIP_DOWNLOAD=yes	nothing re-arms the ort crate download
linux/scripts/01-core/versions.env	$a CARGO_NET_OFFLINE=	nothing re-arms the ort crate download
.github/workflows/ci.yml	s|"1"|"on"|	nothing re-arms the ort crate download
.github/workflows/ci.yml	$a \  ORT_LIB_PATH: /opt/pyke	nothing re-arms the ort crate download
.github/workflows/ci.yml	$a \  ORT_DYLIB_PATH: /opt/pyke/libonnxruntime.so	set only by the two final images
linux/Dockerfile.package	$a ENV ORT_LIB_PATH /root/.cache/ort.pyke.io	nothing re-arms the ort crate download
windows/scripts/build/Build-OpencvFromSource.ps1	$a [Environment]::SetEnvironmentVariable('ORT_LIB_PATH', 'C:/pyke', 'Machine')	nothing re-arms the ort crate download
linux/scripts/03-media/runtime/so-package-map.txt	1s|source-built|libonnxruntime1.23|	so-package-map.txt denies libonnxruntime.so
linux/scripts/03-media/runtime/so-package-map.txt	/^libonnxruntime/d	no libonnxruntime.so* -> source-built deny row
linux/scripts/03-media/runtime/so-package-map.txt	$a libonnxruntime_providers.so\tlibonnxruntime-providers1.23	maps libonnxruntime_providers.so to libonnxruntime-providers1.23
linux/scripts/03-media/build/ffmpeg/ffmpeg-dnn-backends.sh	$a if ffmpeg_probe_pkg_config_feature "libonnxruntime" "libonnxruntime"; then return 0; fi	no vendor libonnxruntime.pc fallback
windows/Dockerfile	/ORT_SKIP_DOWNLOAD=1/d	windows/Dockerfile sets ORT_SKIP_DOWNLOAD=1
windows/Dockerfile	s|\$ONNX_ROOT\\lib|C:\\onnxruntime\\lib|	windows/Dockerfile sets ORT_LIB_LOCATION to the chain lib dir
windows/Dockerfile.media-merge-builder	s|onnxruntime-source|onnxruntime|	ONNX_ROOT is the chain install
linux/Dockerfile.package	/ORT_DYLIB_PATH/d	sets ORT_DYLIB_PATH to the chain library
linux/Dockerfile.package	s|ORT_PREFER_DYNAMIC_LINK=1|ORT_PREFER_DYNAMIC_LINK=0|	sets ORT_PREFER_DYNAMIC_LINK=1
windows/scripts/build/Test-Container.ps1	/Get-OrtCrateEnvFinding/d	the Windows smoke asserts the ort crate env
linux/scripts/06-packaging/smoke-runtime-image.sh	s| ort-crate-env||	the Linux consumer contract asserts the ort crate env
windows/scripts/build/Build-OpencvFromSource.ps1	/Assert-ChainOrtOnly/d	Build-OpencvFromSource.ps1 calls Assert-ChainOrtOnly exactly once
windows/scripts/build/Build-OnnxGenaiFromSource.ps1	/Assert-ChainOrtOnly/d	Build-OnnxGenaiFromSource.ps1 calls Assert-ChainOrtOnly exactly once
windows/scripts/build/Build-FfmpegFromSource.ps1	$a Assert-ChainOrtOnly -Consumer ffmpeg	Build-FfmpegFromSource.ps1 calls Assert-ChainOrtOnly exactly once
windows/scripts/build/Build-OpencvFromSource.ps1	/Get-OpencvOrtConfigureFinding -Log/d	calls Get-OpencvOrtConfigureFinding exactly once
linux/scripts/03-media/build/opencv/build-opencv.sh	/ort_assert_chain_only/d	build-opencv.sh calls ort_assert_chain_only exactly once
linux/scripts/03-media/verify-genai-ort.sh	/ort_assert_chain_only/d	verify-genai-ort.sh calls ort_assert_chain_only exactly once
linux/scripts/03-media/build/opencv/build-opencv.sh	/opencv_ort_assert_configure/d	calls opencv_ort_assert_configure exactly once
linux/scripts/03-media/runtime/validate-media-runtime.sh	/ort_dpkg_gate/d	calls ort_dpkg_gate exactly once
windows/Dockerfile.media-builder	/WindowsOrtProvenance/d	every consumer RUN mounts its G2 helper
windows/Dockerfile.media-builder	$a COPY windows/scripts/modules/WindowsOrtProvenance.Build.psm1 C:/bkmods/	only as per-file bind mounts
windows/scripts/modules/WindowsSourceBuild.Common.psm1	$a Import-Module (Join-Path $PSScriptRoot 'WindowsOrtProvenance.Build.psm1')	is not pulled in by WindowsSourceBuild.Common
linux/Dockerfile.media	1s|03-media/ort-provenance.sh,target=/opt/scripts/03-media/ort-provenance.sh|03-media/core/common.sh,target=/opt/scripts/03-media/core/common.sh|	every consumer RUN mounts its G2 helper
linux/Dockerfile.media	$a COPY linux/scripts/03-media/ort-provenance.sh /opt/scripts/03-media/ort-provenance.sh	only as per-file bind mounts
windows/scripts/build/Test-Container.ps1	/Invoke-OrtImageCensus/d	the Windows smoke runs the ORT census (G1)
linux/scripts/06-packaging/smoke-runtime-image.sh	/check_ort_census/d	the wrapper-smoke stage runs the ORT census (G1)
docs/windows-build-invariants.md	s|^### |## |	lost '### ONNX Runtime has exactly one source
windows/scripts/build/Build-OnnxFromSource.ps1	s|onnx-src|ort-src|	SourceDir ('C:\temp\ort-src') is not the root
linux/scripts/03-media/build/onnxruntime/build/lib/common.sh	s|/opt/onnxruntime|/opt/ort|	ORT_SRC_DIR ('/opt/ort') is not the root
ROWS11

t_case "fix11 — an ort dependency with its default features is pyke's download, in every Cargo shape (mutation)"
cp -a "${_healthy}" "${_work}/cargo-tree"
printf '[dependencies]\nort = "=2.0.0-rc.13"\n' | _write "${_work}/cargo-tree/linux/scripts/x/Cargo.toml"
# The one red case through the REAL gate: the rows above never reach its closing smoke_summary.
_cargo_rc=0
_cargo_out="$(_gate "${_work}/cargo-tree" 2>&1)" || _cargo_rc=$?
t_assert_eq "1" "${_cargo_rc}" "the gate must exit 1 on a FAIL, not just print it"
t_assert_contains "${_cargo_out}" "=== Results: 1 failure(s) ===" "one knocked-out line is one failure"
t_assert_contains "${_cargo_out}" "FAIL fix11: no Cargo.toml here enables" \
  "fix11 runs the Cargo rule: ort's default features carry download-binaries"
_cargo_verdict="$(t_fn_src "${GATE}" _f11_verdict)" || exit 1
_cargo_rule="$(t_fn_src "${GATE}" fix11_ort_cargo)" || exit 1
# _cargo <toml, \n-escaped>: the Cargo rule's one verdict line over a tree holding just that Cargo.toml.
_cargo() {
  local d
  d="$(mktemp -d "${_work}/cargo.XXXXXX")"
  printf '%b' "$1" | _write "${d}/x/Cargo.toml"
  REPO_ROOT="${d}" bash -c 'pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; }'$'\n'"${_cargo_verdict}"$'\n'"${_cargo_rule}"$'\n''fix11_ort_cargo' 2>&1
}
while IFS="$(printf '\t')" read -r _want _toml; do
  [ -n "${_want}" ] || continue
  t_assert_contains "$(_cargo "${_toml}")" "${_want} fix11: no Cargo.toml" "${_toml}"
done <<'CARGO'
PASS	[dependencies]\nort = { version = "=2.0.0-rc.13", default-features = false, features = ["load-dynamic"] }\n
FAIL	[dependencies]\nort-sys = { version = "=2.0.0-rc.13", default-features = false, features = ["download-binaries"] }\n
FAIL	[dependencies.ort]\nversion = "=2.0.0-rc.13"\n
FAIL	[dependencies.ort] # a later table ends it\nversion = "=2.0.0-rc.13"\n[dependencies]\nserde = "1"\n
PASS	[dependencies.ort]\nversion = "=2.0.0-rc.13"\ndefault-features = false\n
FAIL	[target.'cfg(windows)'.dependencies.onnx]\npackage = "ort"\nversion = "=2.0.0-rc.13"\n
PASS	[target.'cfg(windows)'.dependencies.onnx]\npackage = "ort"\ndefault_features = false\n
FAIL	[dependencies]\nonnx = { version = "=2.0.0-rc.13", package = "ort" }\n
PASS	[dependencies]\nonnx = { package = "ort-sys", default-features = false }\n
FAIL	[workspace.dependencies]\n"ort" = "=2.0.0-rc.13"\n
FAIL	[dependencies]\nort.version = "=2.0.0-rc.13"\n
PASS	[dependencies]\nort.version = "=2.0.0-rc.13"\nort.default-features = false\n
FAIL	[dev-dependencies]\nonnx.package = "ort-sys"\nonnx.version = "=2.0.0-rc.13"\n
PASS	[dev-dependencies]\nonnx.package = "ort-sys"\nonnx.default-features = false\n
PASS	[features]\nort = ["dep:ort"]\n[dependencies]\nort = { version = "=2.0.0-rc.13", optional = true, default-features = false }\n
CARGO

t_case "fix11 — every way to SET an ort-sys variable is read, and a READ is not a write (mutation)"
_envw="$(t_fn_src "${GATE}" _f11_env_writes)" || exit 1
while IFS="$(printf '\t')" read -r _line _want; do
  [ -n "${_line}" ] || continue
  printf '%s\n' "${_line}" > "${_work}/corpus"
  t_assert_eq "${_want#-}" "$(bash -c "${_envw}"$'\n''_f11_env_writes "$1"' _ "${_work}/corpus" 2>&1)" "${_line}"
done <<'WRITES'
.github/workflows/ci.yml:3:  ORT_LIB_PATH: /opt/pyke	.github/workflows/ci.yml:3: ort_lib_path=/opt/pyke
.github/workflows/ci.yml:4:  CARGO_NET_OFFLINE:	.github/workflows/ci.yml:4: cargo_net_offline=
l/x.py:1:run(env={"PATH": p, "ORT_OFFLINE": "0"})	l/x.py:1: ort_offline=0
l/x.py:2:os.environ["CARGO_NET_OFFLINE"] = "false"	l/x.py:2: cargo_net_offline=false
linux/Dockerfile.package:9:ENV ORT_LIB_PATH /root/.cache/ort.pyke.io	linux/Dockerfile.package:9: ort_lib_path=/root/.cache/ort.pyke.io
linux/Dockerfile.media:9:ARG ORT_LIB_LOCATION	linux/Dockerfile.media:9: ort_lib_location=
windows/Dockerfile:42:    ORT_SKIP_DOWNLOAD=1 `	windows/Dockerfile:42: ort_skip_download=1
w/B.ps1:1:[Environment]::SetEnvironmentVariable('ORT_LIB_PATH', 'C:/pyke', 'Machine')	w/B.ps1:1: ort_lib_path=c:/pyke
w/B.ps1:2:${env:ORT_STRATEGY} = 'download'	w/B.ps1:2: ort_strategy=download
w/B.ps1:3:Set-Item -Path Env:ORT_LIB_PATH -Value C:/pyke	w/B.ps1:3: ort_lib_path=c:/pyke
w/B.ps1:4:setx /M ORT_SKIP_DOWNLOAD 0	w/B.ps1:4: ort_skip_download=0
l/x.sh:1:ORT_SKIP_DOWNLOAD=Yes cargo build	l/x.sh:1: ort_skip_download=yes
w/T.ps1:1:    if ($v['ORT_LIB_PATH']) { "ORT_LIB_PATH is set" }	-
w/T.ps1:2:    foreach ($n in 'ORT_LIB_LOCATION', 'ORT_LIB_PATH') {	-
w/T.ps1:3:New-Item -ItemType Directory -Path $env:ORT_LIB_LOCATION	-
l/s.sh:1:printf '%s' "${ORT_LIB_PATH-<unset>}" "${ORT_DYLIB_PATH:-}"	-
l/s.sh:2:[[ "${CARGO_NET_OFFLINE}" == 1 ]] || [ $ORT_SKIP_DOWNLOAD == 1 ]	-
l/s.yml:1:  run: echo "ORT_LIB_PATH: ${ORT_LIB_PATH}"	-
WRITES

t_case "fix11 — the healthy fixture passes every fix11 check it has, and no G2 row is vacuous"
_out="${_healthy_out}"
t_assert_contains "${_out}" "PASS fix11: every consumer RUN mounts its G2 helper"
t_assert_contains "${_out}" "PASS fix11: Build-OrtAmdgpuEpFromSource.ps1 calls Assert-ChainOrtOnly exactly once"
t_assert_contains "${_out}" "PASS fix11: the Linux census fingerprints the ORT source root /opt/onnxruntime"
t_assert_contains "${_out}" "PASS fix11: nothing re-arms the ort crate download" "a 1 in ci.yml and both images is not a re-arm"
t_assert_contains "${_out}" "PASS fix11: no Cargo.toml here enables" "the Cargo rule is wired"
t_assert_contains "${_out}" "PASS fix11: nothing deletes or patches an in-box ORT" "the census READING System32's ORT is not a patch"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c -e 'FAIL fix11' || true)" "no fix11 check is red on the healthy tree"
t_assert_contains "${_out}" "PASS fix11: every Linux GenAI build.py call passes --ort_home (2/2)" "the counts reach bash"

t_case "fix11 — a judging pass that dies is a FAIL, never a quiet pass (mutation)"
# Every corpus verdict comes out of one awk run; one that prints nothing would otherwise pass them all.
mkdir -p "${_work}/deadawk"
printf '#!/bin/sh\nexit 2\n' > "${_work}/deadawk/awk"
chmod +x "${_work}/deadawk/awk"
printf 'a/b.sh:1:x\n' > "${_work}/one-line-corpus"
_dead="$(PATH="${_work}/deadawk:${PATH}" bash -c "${_gate_lib}"$'\n'"_F11_RULES=(); _f11_deny never x; _f11_judge '${_work}/one-line-corpus'; smoke_summary" 2>&1)"
t_assert_contains "${_dead}" "got 0 verdict(s) for 1 rule(s) -- the judging pass broke"
t_assert_contains "${_dead}" "=== Results: 1 failure(s) ==="

# ── the in-image half ───────────────────────────────────────────────────────
# CF_SMOKE_ROOT is what makes these provable off-target: the probes read a
# prefixed filesystem, so a fixture root stands in for a shipped image.

_img() { CF_SMOKE_ROOT="$1" TARGET_ARCH="${2:-}" bash "${IMAGE_SMOKE}"; }

# _pc <root> <arch> <prefix line> — one staged python-3.14.pc.
_pc() {
  local pc="$1/opt/python-cross/$2/usr/local/lib/pkgconfig/python-3.14.pc"
  mkdir -p "$(dirname "${pc}")"
  printf 'prefix=%s\nlibdir=${prefix}/lib\n' "$3" > "${pc}"
}

t_case "fix1 — a relocatable \${pcfiledir} prefix is CORRECT, and the shipped trees use it"
# The literal-prefix assertion this replaces reported FAIL on all three arches of
# cross-android-amd64 on 2026-09-05, against a .pc that resolves exactly right.
_root="$(mktemp -d "${_work}/img.XXXXXX")"
_pc "${_root}" amd64 '${pcfiledir}/../..'
_pc "${_root}" arm64 "${_root}/opt/python-cross/arm64/usr/local"
t_assert_eq "0" "$(t_rc _img "${_root}")"
t_assert_contains "$(t_out _img "${_root}")" "prefix resolves to ${_root}/opt/python-cross/amd64/usr/local (amd64)"

t_case "fix1 — a prefix that resolves OUT of the staging tree fails"
_root="$(mktemp -d "${_work}/img.XXXXXX")"
_pc "${_root}" amd64 '${pcfiledir}/../../../../..'
t_assert_eq "1" "$(t_rc _img "${_root}")"
t_assert_contains "$(t_out _img "${_root}")" "outside ${_root}/opt/python-cross/amd64"

t_case "fix1/fix3 — an image with no staging tree SKIPs instead of failing"
_root="$(mktemp -d "${_work}/img.XXXXXX")"
t_assert_contains "$(t_out _img "${_root}")" "SKIP: no per-arch python-3.14.pc found"
t_assert_contains "$(t_out _img "${_root}")" "SKIP: no per-arch lib-dynload found"

t_case "fix2 — absl is looked for where install_abseil_headers PUTS it"
# The three dirs the old probe searched are none of them the install prefix, so
# it reported FAIL against an image that carries absl exactly where it belongs.
_root="$(mktemp -d "${_work}/img.XXXXXX")"
mkdir -p "${_root}/usr/local/include/absl/types"
: > "${_root}/usr/local/include/absl/types/span.h"
t_assert_contains "$(t_out _img "${_root}")" "absl/types/span.h found in ${_root}/usr/local/include"

t_case "fix2 — headers that include absl/ with no absl shipped is the REAL defect"
# Measured in latest-cross-{amd64,arm64,riscv64} on 2026-09-05: 1322 LiteRT
# headers, 707 of them including absl/, and no absl directory at all.
_root="$(mktemp -d "${_work}/img.XXXXXX")"
mkdir -p "${_root}/usr/local/include/tflite"
printf '#include "absl/types/span.h"\n' > "${_root}/usr/local/include/tflite/util.h"
t_assert_eq "1" "$(t_rc _img "${_root}")"
t_assert_contains "$(t_out _img "${_root}")" "cannot build"

t_case "fix2 — no LiteRT headers at all SKIPs; an EMPTY stub dir is not evidence"
# /usr/local/include/tensorflow ships as two empty directories on all three
# arches, and the old probe treated that stub as proof LiteRT was present.
_root="$(mktemp -d "${_work}/img.XXXXXX")"
mkdir -p "${_root}/usr/local/include/tensorflow/lite"
t_assert_eq "0" "$(t_rc _img "${_root}")"
t_assert_contains "$(t_out _img "${_root}")" "SKIP: no LiteRT headers that include absl/"

t_case "fix3 — a dangling lib-dynload symlink fails, a resolving one does not"
_root="$(mktemp -d "${_work}/img.XXXXXX")"
_dyn="${_root}/opt/python-cross/riscv64/usr/local/lib/python3.14/lib-dynload"
mkdir -p "${_dyn}"
: > "${_dyn}/_ssl.so"
ln -s _ssl.so "${_dyn}/_ssl.alias.so"
t_assert_eq "0" "$(t_rc _img "${_root}")"
ln -s _gone.so "${_dyn}/_zstd.so"
t_assert_eq "1" "$(t_rc _img "${_root}")"
t_assert_contains "$(t_out _img "${_root}")" "1 dangling symlinks found in lib-dynload (riscv64)"

t_case "fix4 — the native cc must be the TARGET arch, not the builder's"
# This is the assertion the whole battery exists for: a foreign-arch image whose
# cc is still the builder's compiler.
_root="$(mktemp -d "${_work}/img.XXXXXX")"
_other=riscv64
[ "$(uname -m)" = "riscv64" ] && _other=arm64
if command -v cc >/dev/null 2>&1; then
  t_assert_eq "1" "$(t_rc _img "${_root}" "${_other}")"
  t_assert_contains "$(t_out _img "${_root}" "${_other}")" "cc -dumpmachine reports"
else
  t_assert_eq "0" "$(t_rc _img "${_root}" "${_other}")"
  t_assert_contains "$(t_out _img "${_root}" "${_other}")" "SKIP: cc not found"
fi

t_case "the packaging answer to fix2 — the payload copy carries absl, not just the headers that need it"
# copy_media_payloads copied /usr/local/include/{tflite,tensorflow,flatbuffers,c}
# and left absl behind, which is why the probe above is red on shipped bytes.
_PAY="$(cat "${PAYLOADS}")"
t_assert_contains "${_PAY}" "/usr/local/include/absl" "the LiteRT headers it copies include absl/"
t_assert_contains "${_PAY}" "/usr/local/include/tflite" "and the headers themselves are still copied"

t_summary
