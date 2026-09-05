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
  printf '%s' "${d}"
}

_gate() { bash "$1/linux/scripts/verify-critical-fixes.sh"; }

# _red <relpath> <sed expr> <expected message> — one guarded line knocked out.
_red() {
  local d expr="$2"
  d="$(_tree)"
  sed -i -e "${expr}" "${d}/$1"
  t_assert_eq "1" "$(t_rc _gate "${d}")" "knocking out $1 must fail the gate"
  t_assert_contains "$(t_out _gate "${d}")" "$3" "wrong finding for $1 / ${expr}"
}

t_case "a healthy tree passes — without this the reds below prove nothing"
_fix="$(_tree)"
t_assert_eq "0" "$(t_rc _gate "${_fix}")"
t_assert_contains "$(t_out _gate "${_fix}")" "=== Results: 0 failure(s) ==="
t_assert_contains "$(t_out _gate "${_fix}")" "Critical Fixes: host tree checks"

t_case "the /opt-probing half is GONE from the host gate"
# It skipped on every host run it ever had, and fix4 was a tautology there
# (host cc is the host arch). Its real verdicts live in smoke-critical-fixes.sh.
for _moved in "Fix 1:" "Fix 2:" "Fix 3:" "Fix 4:"; do
  case "$(t_out _gate "${_fix}")" in
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
  _red "${_f}" "${_e//@LHS@/${_bare_export_lhs}}" "${_m}"
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
