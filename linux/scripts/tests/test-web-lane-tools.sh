#!/usr/bin/env bash
# 06-packaging/web-lane-tools.sh off-target: the key, the fail-loud gate, the binary cache,
# the auto|cross|native|legacy selection, the android-side producer and the Dockerfile wiring.
# docs/consumer-image-contract.md#building-the-web-lane-tools-from-source
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# An operator's exported switch must not decide a case; each case sets its own.
unset WEB_LANE_TOOLS_SOURCE WEB_LANE_TOOLS_CACHE WEB_LANE_TOOLS_CROSS_ARCHES
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
LIB="${SCRIPTS}/06-packaging/web-lane-tools.sh"
FX="${TESTS_DIR}/web-lane-fixtures.sh"
PLATFORM="${SCRIPTS}/01-core/platform.sh"
DF_ANDROID="${SCRIPTS}/../Dockerfile.android"
DF_PACKAGE="${SCRIPTS}/../Dockerfile.package"
_SB_ROOT="$(mktemp -d)"
trap 'rm -rf "${_SB_ROOT}"' EXIT

# _wlt <snippet>: <snippet> in a child bash with platform.sh, the fixtures and the library
# loaded, CARGO_HOME/cache/artifact/provenance in a fresh sandbox ($SB); then "rc=<n>".
# Hermetic: the caller's arch and Rust build env never reach it (the CI image exports
# TARGET_ARCH=amd64); WLT_T_ARCH (default riscv64) is the fixture's target arch.
_wlt() {
  local sb
  sb="$(mktemp -d "${_SB_ROOT}/sb.XXXXXX")"
  mkdir -p "${sb}/home" "${sb}/cache" "${sb}/artifact"
  env -u TARGETARCH -u TARGETPLATFORM -u BUILDARCH -u BUILDPLATFORM -u BUILD_MODE \
    -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS -u CARGO_BUILD_RUSTFLAGS -u CARGO_TARGET_DIR \
    -u RUSTC_WRAPPER -u BZIP2_NO_PKG_CONFIG -u LZMA_API_STATIC -u ZSTD_SYS_USE_PKG_CONFIG \
    SB="${sb}" CARGO_HOME="${sb}/home" WLT_CACHE_DIR="${sb}/cache" WLT_ARTIFACT_DIR="${sb}/artifact" \
    WLT_PROVENANCE="${sb}/provenance" TARGET_ARCH="${WLT_T_ARCH:-riscv64}" \
    FAKE_TIMEOUT_LOG="${sb}/timeout.log" WASM_PACK_VERSION=0.15.0 FLUTTER_RUST_BRIDGE_VERSION=2.13.0 \
    bash -c 'set -uo pipefail
      source "$1"; source "$2"; source "$3"
      wlt_fx_home "${CARGO_HOME}"
      eval "$4"
      echo "rc=$?"' _ "${PLATFORM}" "${FX}" "${LIB}" "$1" 2>&1
}
_count() { printf '%s\n' "$1" | grep -c -e "$2" || true; }
_assert_no_build() {  # <out> <rc> <why>: nothing was compiled, and the snippet ended with <rc>
  t_assert_eq 0 "$(_count "$1" '^CARGO ')" "$3"
  t_assert_contains "$1" "rc=$2"
}
_assert_native() {  # <out> <rc>: wasm-pack was compiled natively, into a scratch root, then <rc>
  t_assert_contains "$1" "CARGO install --locked wasm-pack --version 0.15.0 --root "
  t_assert_contains "$1" "rc=$2"
}

# ---- 1. the key --------------------------------------------------------------------
t_case "the key is deterministic, and every one of its eight fields changes it"
_out="$(_wlt '
  k() { wlt_key "$(wlt_key_text "${1:-wasm-pack}" "${2:-0.15.0}" "${3:-riscv64gc-unknown-linux-gnu}" "${4:-1.98.1}" "${5--C x}")"; }
  base="$(k)"; [ "$(k)" = "${base}" ] && echo SAME
  for v in "tool=frb" "version=0.14.0" "target=aarch64-unknown-linux-gnu" "rustc=1.98.0" "rustflags="; do
    case "${v}" in
      tool=*) o="$(k frb)" ;; version=*) o="$(k "" 0.14.0)" ;; target=*) o="$(k "" "" aarch64-unknown-linux-gnu)" ;;
      rustc=*) o="$(k "" "" "" 1.98.0)" ;; rustflags=*) o="$(k "" "" "" "" "")" ;;
    esac
    [ "${o}" != "${base}" ] && echo "KEYED ${v%%=*}"
  done
  [ "$(WLT_KEY_SCHEMA=2; k)" != "${base}" ] && echo "KEYED schema"
  [ "$(WLT_C_ENV_KEY=x; k)" != "${base}" ] && echo "KEYED c_env"
  [ "$(WLT_CARGO_ARGS=--frozen; k)" != "${base}" ] && echo "KEYED cargo_args"
  printf "%s\n" "$(wlt_key_text a b c d e)" | wc -l | tr -d " "')"
t_assert_contains "${_out}" "SAME"

for _f in tool version target rustc rustflags schema c_env cargo_args; do
  t_assert_contains "${_out}" "KEYED ${_f}" "a field outside the key lets two different builds share one cache entry"
done
t_assert_contains "${_out}" $'\n8\nrc=0' "the manifest's first eight lines ARE the key text"

t_case "WLT_C_ENV_KEY is exactly what wlt_c_env does"
_out="$(_wlt 'ZSTD_SYS_USE_PKG_CONFIG=1; export ZSTD_SYS_USE_PKG_CONFIG; wlt_c_env
  echo "BZIP2_NO_PKG_CONFIG=${BZIP2_NO_PKG_CONFIG} LZMA_API_STATIC=${LZMA_API_STATIC} -ZSTD_SYS_USE_PKG_CONFIG${ZSTD_SYS_USE_PKG_CONFIG+ STILL-SET}"
  echo "${WLT_C_ENV_KEY}"')"
t_assert_eq 2 "$(_count "${_out}" '^BZIP2_NO_PKG_CONFIG=1 LZMA_API_STATIC=1 -ZSTD_SYS_USE_PKG_CONFIG$')" \
  "the key text would claim a C env the build never had"

# ---- 2. the gate, against stubbed readelf output --------------------------------------
# $1 = facts for the fake binary, $2 = what --version prints; runs the full gate.
_gate() {
  _wlt 'wlt_fx_bin "${SB}/t" wasm-pack "'"${2:-0.15.0}"'" '"$1"'
    wlt_assert_binary wasm-pack "${SB}/t" riscv64 2.43 0.15.0; r=$?; echo "WHY=${_WLT_WHY}"; (exit "${r}")'
}

t_case "a healthy riscv64 binary passes every check"
t_assert_contains "$(_gate "")" "rc=0" "lp64d, the riscv64 loader, allowed NEEDED, GLIBC 2.39 <= 2.43, --version"

for _bad in \
  "machine=Advanced Micro Devices X86-64|ELF machine (Advanced Micro Devices X86-64 vs RISC-V)" \
  "class=ELF32|ELF class (ELF32 vs ELF64)" \
  "flags=0x1, RVC, soft-float ABI|riscv64 float ABI" \
  "interp=/lib/ld-musl-riscv64.so.1|PT_INTERP (/lib/ld-musl-riscv64.so.1 vs /lib/ld-linux-riscv64-lp64d.so.1)" \
  "needed=libc.so.6 libbz2.so.1|NEEDED (libbz2.so.1 vs" \
  "glibc=2.44|max GLIBC (2.44 vs <= 2.43)" \
  "glibc=none|GLIBC version needs (none vs at least one GLIBC_ entry)"; do
  t_case "the gate refuses ${_bad%%|*}"
  _out="$(_gate "'${_bad%%|*}'")"
  t_assert_contains "${_out}" "WHY=${_bad#*|}" "the failure must say what and why"
  t_assert_contains "${_out}" "rc=1"
done

t_case "the gate refuses a binary whose --version is not the pin"
_out="$(_gate "" 0.14.0)"
t_assert_contains "${_out}" "WHY=--version (wasm-pack 0.14.0 vs wasm-pack 0.15.0)"
t_assert_contains "${_out}" "rc=1"

t_case "no readelf is a refusal, never platform.sh's WARN-and-pass"
_out="$(_wlt 'wlt_fx_bin "${SB}/t" wasm-pack 0.15.0; unset -f readelf; PATH="${SB}/empty"
  wlt_assert_binary wasm-pack "${SB}/t" riscv64 2.43 0.15.0; r=$?; echo "WHY=${_WLT_WHY}"; (exit "${r}")')"
t_assert_contains "${_out}" "WHY=readelf (none vs binutils on PATH)"
t_assert_contains "${_out}" "rc=1"

# ---- 3. real bytes, real readelf ---------------------------------------------------
t_case "real readelf: an x86-64 ELF presented as riscv64 is refused"
if command -v readelf >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  t_fake_elf "${_SB_ROOT}/x86.elf" 62
  t_fake_elf "${_SB_ROOT}/rv.elf" 243
  _real() {
    bash -c 'source "$1"; source "$2"; wlt_assert_binary t "$3" riscv64; r=$?; echo "WHY=${_WLT_WHY}"; exit "${r}"' \
      _ "${PLATFORM}" "${LIB}" "$1" 2>&1
  }
  t_assert_contains "$(_real "${_SB_ROOT}/x86.elf")" "WHY=ELF machine (Advanced Micro Devices X86-64 vs RISC-V)"
  t_case "real readelf: a RISC-V ELF without the double-float ABI flag is refused"
  t_assert_contains "$(_real "${_SB_ROOT}/rv.elf")" "WHY=riscv64 float ABI (0x0 vs double-float ABI (lp64d))"
else
  t_assert_contains "$(bash -c 'source "$1"; wlt_assert_binary t /bin/sh riscv64; echo "WHY=${_WLT_WHY}"' _ "${LIB}" 2>&1)" \
    "WHY=readelf" "no readelf on this host: the gate must still refuse"
fi

# ---- 4. the cache ------------------------------------------------------------------
# A healthy native-key entry for wasm-pack, as a previous native build stores it.
_SEED='k="$(wlt_key_text wasm-pack 0.15.0 riscv64gc-unknown-linux-gnu 1.98.1 "")"
  e="$(wlt_cache_entry "${k}")"
  wlt_fx_bin "${SB}/seed" wasm-pack 0.15.0 >/dev/null
  wlt_cache_store wasm-pack "${e}" "${k}" "${SB}/seed" native:riscv64 >/dev/null'

t_case "a verified cache hit installs without invoking cargo"
_out="$(WEB_LANE_TOOLS_SOURCE=native _wlt "${_SEED}"'
  wlt_install_from_source wasm-pack 0.15.0; r=$?; cat "${WLT_PROVENANCE}"; [ -x "${CARGO_HOME}/bin/wasm-pack" ] && echo INSTALLED; (exit "${r}")')"
t_assert_contains "${_out}" "cache HIT wasm-pack-0.15.0_rust-1.98.1_riscv64gc-unknown-linux-gnu_"
t_assert_contains "${_out}" "source=cache"
t_assert_contains "${_out}" "INSTALLED"
_assert_no_build "${_out}" 0 "a hit must not recompile"

for _rej in \
  "a stale-version entry|sed -i s/^version=0.15.0/version=0.14.0/ \"\${e}/manifest\"|its key text is not this build's" \
  "a foreign-machine entry|wlt_fx_bin \"\${e}/wasm-pack\" wasm-pack 0.15.0 arch=amd64; sed -i \"s/^sha256=.*/sha256=\$(wlt_sha256 \"\${e}/wasm-pack\")/\" \"\${e}/manifest\"|ELF machine (Advanced Micro Devices X86-64 vs RISC-V)" \
  "a sha-tampered entry|echo tampered >> \"\${e}/wasm-pack\"|sha256 ("; do
  IFS='|' read -r _name _mutate _why <<< "${_rej}"
  t_case "${_name} is rejected, deleted and rebuilt"
  _out="$(WEB_LANE_TOOLS_SOURCE=native _wlt "${_SEED}; ${_mutate}"'
    wlt_install_from_source wasm-pack 0.15.0; r=$?; ls "${WLT_CACHE_DIR}" | grep -c "_rust-" ; (exit "${r}")')"
  t_assert_contains "${_out}" "rejected: ${_why}"
  t_assert_eq 1 "$(_count "${_out}" '^CARGO install --locked wasm-pack --version 0.15.0')" "rebuilt once"
  t_assert_contains "${_out}" "cached as wasm-pack-0.15.0_rust-1.98.1" "and the rebuild replaces the bad entry"
  t_assert_contains "${_out}" "rc=0"
done

t_case "WEB_LANE_TOOLS_CACHE=off neither reads nor writes"
_out="$(WEB_LANE_TOOLS_SOURCE=native WEB_LANE_TOOLS_CACHE=off _wlt 'wlt_install_from_source wasm-pack 0.15.0
  r=$?; echo "entries=$(ls "${WLT_CACHE_DIR}" | wc -l | tr -d " ")"; (exit "${r}")')"
t_assert_contains "${_out}" "CARGO install --locked wasm-pack --version 0.15.0"
t_assert_contains "${_out}" "entries=0"
_out="$(WEB_LANE_TOOLS_SOURCE=native WEB_LANE_TOOLS_CACHE=off _wlt "${_SEED}"'; wlt_install_from_source wasm-pack 0.15.0')"
t_assert_contains "${_out}" "CARGO install --locked" "off must not read a valid entry either"

t_case "WEB_LANE_TOOLS_CACHE=refresh rebuilds past a valid entry and stores the result"
_out="$(WEB_LANE_TOOLS_SOURCE=native WEB_LANE_TOOLS_CACHE=refresh _wlt "${_SEED}"'; wlt_install_from_source wasm-pack 0.15.0')"
t_assert_eq 0 "$(_count "${_out}" 'cache HIT')" "refresh never reads"
t_assert_contains "${_out}" "CARGO install --locked wasm-pack"
t_assert_contains "${_out}" "cached as wasm-pack-0.15.0"

t_case "a failed store leaves no entry and no temp dir behind"
_out="$(_wlt 'wlt_cache_store wasm-pack "${WLT_CACHE_DIR}/x" key "${SB}/missing" native:riscv64; ls -A "${WLT_CACHE_DIR}" | wc -l | tr -d " "')"
t_assert_contains "${_out}" "the cache store failed"
t_assert_contains "${_out}" $'\n0\nrc=0' "a store that cannot complete must not become visible"

t_case "the cache keeps the newest three entries per tool"
_out="$(_wlt 'wlt_fx_bin "${SB}/b" wasm-pack 0.15.0
  for i in 1 2 3 4 5; do wlt_cache_store wasm-pack "${WLT_CACHE_DIR}/wasm-pack-0.1.${i}_rust-1_t_${i}" "k${i}" "${SB}/b" n >/dev/null
    touch -d "2026-01-0${i}" "${WLT_CACHE_DIR}/wasm-pack-0.1.${i}_rust-1_t_${i}"; done
  wlt_cache_store wasm-pack "${WLT_CACHE_DIR}/wasm-pack-0.1.6_rust-1_t_6" k6 "${SB}/b" n >/dev/null; ls "${WLT_CACHE_DIR}"')"
t_assert_contains "${_out}" "wasm-pack-0.1.6_rust-1_t_6"
t_assert_contains "${_out}" "wasm-pack-0.1.5_rust-1_t_5"
t_assert_contains "${_out}" "wasm-pack-0.1.4_rust-1_t_4"
t_assert_eq 0 "$(_count "${_out}" 'wasm-pack-0.1.3_')" "a pin bump must not grow the cache without bound"

# ---- 5. auto | cross | native | legacy -------------------------------------------------
_install() { _wlt "$1"'
  wlt_install_from_source wasm-pack 0.15.0; r=$?; cat "${WLT_PROVENANCE}" 2>/dev/null; (exit "${r}")'; }
_SKIP='_wlt_mark "${WLT_ARTIFACT_DIR}/riscv64gc-unknown-linux-gnu" wasm-pack skipped "native-build-platform: x"'
_FAIL='_wlt_mark "${WLT_ARTIFACT_DIR}/riscv64gc-unknown-linux-gnu" wasm-pack failed "cargo install exited 101: boom"'
_OK='wlt_fx_artifact wasm-pack 0.15.0 riscv64'

t_case "auto + a good cross artifact installs it, no cargo"
_out="$(_install "${_OK}")"
t_assert_contains "${_out}" "OK: wasm-pack 0.15.0 installed from the cross-built artifact"
t_assert_contains "${_out}" "source=cross"
_assert_no_build "${_out}" 0 "the artifact replaces the compile"

t_case "auto + a skipped producer builds natively (the X100 shape)"
_out="$(_install "${_SKIP}")"
t_assert_contains "${_out}" "NOTE: web-lane wasm-pack: the cross producer skipped riscv64 (native-build-platform: x)"
t_assert_contains "${_out}" "source=native"
_assert_native "${_out}" 0

for _c in "absent||the cross artifact is absent" "failed|${_FAIL}|the cross artifact is failed (cargo install exited 101: boom)" \
          "key skew|FAKE_RUSTC=1.98.0 ${_OK}|the cross artifact was built for another key (pin or toolchain skew)"; do
  IFS='|' read -r _name _setup _why <<< "${_c}"
  t_case "auto + ${_name} WARNs and builds natively"
  _out="$(_install "${_setup}")"
  t_assert_contains "${_out}" "WARN: web-lane wasm-pack: ${_why}"
  t_assert_contains "${_out}" "the cross fast path was not taken"
  _assert_native "${_out}" 0
  t_case "cross + ${_name} is fatal"
  _out="$(WEB_LANE_TOOLS_SOURCE=cross _install "${_setup}")"
  t_assert_contains "${_out}" "ERROR: web-lane wasm-pack: WEB_LANE_TOOLS_SOURCE=cross, but ${_why}"
  _assert_no_build "${_out}" 1 "cross must not quietly fall back"
done

t_case "cross + a skipped producer builds natively: nothing was expected for this arch"
_assert_native "$(WEB_LANE_TOOLS_SOURCE=cross _install "${_SKIP}")" 0

for _c in "a bad sha256|${_OK}; echo x >> \"\${WLT_ARTIFACT_DIR}\"/riscv64gc-unknown-linux-gnu/bin/wasm-pack|sha256 (" \
          "a GLIBC above the image's|${_OK} glibc=2.44|max GLIBC (2.44 vs <= 2.43)"; do
  IFS='|' read -r _name _setup _why <<< "${_c}"
  for _mode in auto cross; do
    t_case "${_mode} + an ok artifact with ${_name} is fatal: it claims to be good"
    _out="$(WEB_LANE_TOOLS_SOURCE="${_mode}" _install "${_setup}")"
    t_assert_contains "${_out}" "ERROR: web-lane wasm-pack: the cross artifact claims status=ok, but ${_why}"
    _assert_no_build "${_out}" 1 "a defect is not an availability miss"
  done
done

t_case "native never reads the artifact, however good it is"
_out="$(WEB_LANE_TOOLS_SOURCE=native _install "${_OK}")"
_assert_native "${_out}" 0
t_assert_eq 0 "$(_count "${_out}" 'cross-built artifact')"
t_assert_contains "${_out}" "source=native"

t_case "native compiles in the package stage with rv64gc Rust and vendored static C"
t_assert_contains "${_out}" "rustflags=[]" "native stays rv64gc Rust"
t_assert_contains "${_out}" "bzip2=1 lzma=1 zstd=unset"

t_case "native installs a bare binary: cargo's .crates.toml stays in the scratch root"
_out="$(WEB_LANE_TOOLS_SOURCE=native _wlt 'wlt_install_from_source wasm-pack 0.15.0; r=$?
  [ -x "${CARGO_HOME}/bin/wasm-pack" ] && echo INSTALLED; [ -e "${CARGO_HOME}/.crates.toml" ] && echo CRATES-TOML; (exit "${r}")')"
t_assert_contains "${_out}" "INSTALLED"
t_assert_eq 0 "$(_count "${_out}" '^CRATES-TOML$')" "the docs say native ships no crates metadata; legacy is the leg that does"

t_case "a native build that fails its gate is fatal; a failed cargo is not"
_out="$(WEB_LANE_TOOLS_SOURCE=native FAKE_BUILD_FACTS='needed=libc.so.6 libbz2.so.1' _install '')"
t_assert_contains "${_out}" "ERROR: web-lane wasm-pack: cargo reported success, but the native build fails NEEDED (libbz2.so.1"
t_assert_contains "${_out}" "rc=1"
_out="$(WEB_LANE_TOOLS_SOURCE=native FAKE_CARGO_RC=101 _install '')"
t_assert_contains "${_out}" "WARN: cargo install wasm-pack 0.15.0 failed; the web lane will build it per run"
t_assert_contains "${_out}" "rc=0"

t_case "legacy is the pre-2026-09-23 leg verbatim: cargo's own install, the stage's own env"
_out="$(WEB_LANE_TOOLS_SOURCE=legacy _wlt "${_OK}; ${_SEED}"'
  export RUSTFLAGS="-C inherited" ZSTD_SYS_USE_PKG_CONFIG=1
  wlt_install_from_source wasm-pack 0.15.0; r=$?
  [ -x "${CARGO_HOME}/bin/wasm-pack" ] && echo INSTALLED
  grep -q "^\"wasm-pack 0.15.0 " "${CARGO_HOME}/.crates.toml" && echo CRATES-TOML
  [ -e "${WLT_PROVENANCE}" ] && echo PROVENANCE
  echo "entries=$(ls "${WLT_CACHE_DIR}" | wc -l | tr -d " ")"; (exit "${r}")')"
t_assert_eq 1 "$(_count "${_out}" '^CARGO install --locked wasm-pack --version 0.15.0$')" \
  "no --root and no --target: the command the package stage ran before this file existed"
t_assert_contains "${_out}" "bzip2=unset lzma=unset zstd=1 wrapper=[unset] rustflags=[-C inherited]" \
  "legacy forces no C env and no flags: whatever the stage has, as before"
t_assert_contains "${_out}" "OK: wasm-pack 0.15.0 installed"
t_assert_contains "${_out}" "INSTALLED"
t_assert_contains "${_out}" "CRATES-TOML" "cargo records it, so a consumer's cargo install says 'already installed'"
t_assert_eq 0 "$(_count "${_out}" 'cross-built artifact\|cache HIT\|^PROVENANCE$')" \
  "legacy reads neither the artifact nor the cache, and writes no provenance"
t_assert_contains "${_out}" "entries=1" "and stores nothing: the seeded entry is all there is"
t_assert_contains "${_out}" "rc=0"

t_case "legacy is ungated and non-fatal, and needs neither rustc -V nor getconf"
_out="$(WEB_LANE_TOOLS_SOURCE=legacy FAKE_BUILD_FACTS='needed=libc.so.6 libbz2.so.1' FAKE_GLIBC='' \
  _install 'rm -f "${CARGO_HOME}/bin/rustc"')"
t_assert_contains "${_out}" "OK: wasm-pack 0.15.0 installed" "the old leg installed whatever cargo built"
t_assert_contains "${_out}" "rc=0"
_out="$(WEB_LANE_TOOLS_SOURCE=legacy FAKE_CARGO_RC=101 _install '')"
t_assert_contains "${_out}" "WARN: cargo install wasm-pack 0.15.0 failed; the web lane will build it per run"
t_assert_contains "${_out}" "rc=0"

t_case "no rustc release: auto WARNs and skips; cross ERRORs where an artifact was expected"
_out="$(_install "${_OK}"'; rm -f "${CARGO_HOME}/bin/rustc"')"
t_assert_contains "${_out}" "WARN: web-lane wasm-pack: rustc -V reports no release; the web lane will build it per run"
t_assert_eq 0 "$(_count "${_out}" 'installed from')" "nothing can be keyed, so nothing is installed"
_assert_no_build "${_out}" 0 "and nothing is built"
_out="$(WEB_LANE_TOOLS_SOURCE=cross _install "${_OK}"'; rm -f "${CARGO_HOME}/bin/rustc"')"
t_assert_contains "${_out}" "ERROR: web-lane wasm-pack: WEB_LANE_TOOLS_SOURCE=cross, but rustc -V reports no release to key the artifact by"
_assert_no_build "${_out}" 1 "cross must not quietly skip the artifact it was asked to prove"
_out="$(WEB_LANE_TOOLS_SOURCE=cross _install "${_SKIP}"'; rm -f "${CARGO_HOME}/bin/rustc"')"
t_assert_contains "${_out}" "WARN: web-lane wasm-pack: rustc -V reports no release"
_assert_no_build "${_out}" 0 "a skipped arch expected no artifact: availability, as for amd64/arm64"

t_case "an image whose glibc cannot be read installs nothing: no binary can be bounded"
_out="$(FAKE_GLIBC='' _install "${_OK}")"
t_assert_contains "${_out}" "ERROR: web-lane: getconf GNU_LIBC_VERSION reports nothing"
t_assert_eq 0 "$(_count "${_out}" 'installed from')"
_assert_no_build "${_out}" 1 "an unbounded GLIBC check is a skipped check"

t_case "a failed install is fatal and records no provenance"
_out="$(_install "${_OK}"'; install() { return 1; }')"
t_assert_contains "${_out}" "ERROR: web-lane wasm-pack: install into "
t_assert_eq 0 "$(_count "${_out}" '^tool=wasm-pack')" "provenance must not claim an install that did not happen"
t_assert_contains "${_out}" "rc=1"

t_case "a bad knob is fatal, before anything is built"
_out="$(WEB_LANE_TOOLS_SOURCE=qemu _install '')"
t_assert_contains "${_out}" "ERROR: WEB_LANE_TOOLS_SOURCE='qemu' (want auto, cross, native or legacy)"
t_assert_contains "${_out}" "rc=1"
_out="$(WEB_LANE_TOOLS_CACHE=yes _install '')"
t_assert_contains "${_out}" "ERROR: WEB_LANE_TOOLS_CACHE='yes' (want on, refresh or off)"
t_assert_contains "${_out}" "rc=1"

# ---- 6. the producer ---------------------------------------------------------------
# $1 = the snippet's prelude; runs wlt_produce into $SB/out against a fixture 01-core,
# then prints the manifests, the emitted binaries and every timeout the run went through.
_produce() {
  _wlt 'wlt_fx_core "${SB}/core"; WLT_CORE_DIR="${SB}/core"; '"$1"'
    wlt_produce "${SB}/out"; r=$?; for m in "${SB}"/out/*/*.manifest; do echo "== ${m##*/}"; cat "${m}"; done
    ls "${SB}"/out/*/bin 2>/dev/null; cat "${FAKE_TIMEOUT_LOG}" 2>/dev/null; (exit "${r}")'
}

for _c in "riscv64|FAKE_BUILD_ARCH=riscv64|native-build-platform: this riscv64 builder" \
          "arm64||not in WEB_LANE_TOOLS_CROSS_ARCHES=riscv64" \
          "riscv64|WEB_LANE_TOOLS_CROSS_ARCHES=none|disabled: WEB_LANE_TOOLS_CROSS_ARCHES=none"; do
  IFS='|' read -r _arch _env _why <<< "${_c}"
  t_case "the producer skips ${_arch} (${_why%%:*})"
  _out="$(WLT_T_ARCH="${_arch}" _produce "${_env:+export ${_env}}")"
  t_assert_eq 2 "$(_count "${_out}" "^reason=${_why}")" "both tools carry the reason the package stage prints"
  t_assert_eq 2 "$(_count "${_out}" '^status=skipped')"
  _assert_no_build "${_out}" 0 "a skip compiles nothing"
done

t_case "a bad WEB_LANE_TOOLS_CROSS_ARCHES fails the android stage"
_out="$(_produce 'export WEB_LANE_TOOLS_CROSS_ARCHES=riscv64,x86')"
t_assert_contains "${_out}" "ERROR: WEB_LANE_TOOLS_CROSS_ARCHES="
t_assert_contains "${_out}" "rc=1"

t_case "the cross build: the pinned argv, a scratch target dir, no wrapper, vendored C, RVV"
_out="$(_produce '')"
t_assert_contains "${_out}" "--target riscv64gc-unknown-linux-gnu wasm-pack --version 0.15.0"
t_assert_contains "${_out}" "CARGO install --locked --root "
t_assert_contains "${_out}" "--target riscv64gc-unknown-linux-gnu flutter_rust_bridge_codegen --version 2.13.0"
t_assert_eq 0 "$(_count "${_out}" 'target_dir=/opt/cargo-target')" "cross-env.sh's default would land ~390 MB in the stage"
t_assert_eq 0 "$(_count "${_out}" 'target_dir=unset')"
t_assert_contains "${_out}" "bzip2=1 lzma=1 zstd=unset wrapper=[] rustflags=[-C target-feature=+v,+zvl128b]"
t_assert_eq 2 "$(_count "${_out}" '^status=ok')"
t_assert_eq 2 "$(_count "${_out}" '^built_by=cross:amd64')"
t_assert_eq 1 "$(_count "${_out}" '^wasm-pack$')" "the binary is emitted beside its manifest"
t_assert_eq 2 "$(_count "${_out}" '^TIMEOUT 1800 cargo$')" \
  "every cross cargo runs under the 30-minute bound: a hung crates.io fetch must not stall android"

for _v in BUILDARCH=arm64 BUILDPLATFORM=linux/arm64; do
  t_case "the build arch is the one the RUN executes on, not an inherited ${_v%%=*}"
  _out="$(_produce "export ${_v}")"
  t_assert_eq 2 "$(_count "${_out}" '^built_by=cross:amd64')" \
    "android-sdk's ENV names the builder node (a Jetson, arm64) while the RUN executes amd64 under QEMU"
  t_assert_eq 0 "$(_count "${_out}" 'cross:arm64')"
done

t_case "the producer's output is what the consumer accepts (one key, two sides)"
_out="$(_wlt 'wlt_fx_core "${SB}/core"; WLT_CORE_DIR="${SB}/core"; ( wlt_produce "${WLT_ARTIFACT_DIR}" ) >/dev/null
  wlt_install_from_source wasm-pack 0.15.0')"
t_assert_contains "${_out}" "installed from the cross-built artifact"
t_assert_contains "${_out}" "rc=0"

t_case "the producer's own cache: a second run compiles nothing"
_out="$(_produce '( wlt_produce "${SB}/out" ) >/dev/null; rm -rf "${SB}/out"')"
t_assert_eq 2 "$(_count "${_out}" 'cache HIT')"
_assert_no_build "${_out}" 0 "a warm producer cache replaces the compile"

for _c in "FAKE_CARGO_RC=101|cargo install exited 101: error: could not compile (fake)" \
          "FAKE_BUILD_FACTS=\"needed=libc.so.6 libbz2.so.1\"|NEEDED (libbz2.so.1" \
          "FAKE_BUILD_FACTS=\"glibc=2.44\"|max GLIBC (2.44 vs <= 2.43)" \
          "FAKE_CROSS_ENV_RC=1|setup_linux_cross_env failed: no cross toolchain for riscv64" \
          "FAKE_CROSS_RUSTFLAGS=\"-C target-feature=+v\"|RUSTFLAGS drift (-C target-feature=+v vs -C target-feature=+v,+zvl128b)" \
          "WASM_PACK_VERSION=|no wasm-pack version build-arg reached the android stage"; do
  t_case "the producer records status=failed, never fails android: ${_c%%|*}"
  _out="$(_produce "export ${_c%%|*}")"
  t_assert_contains "${_out}" "reason=${_c#*|}"
  t_assert_eq 0 "$(_count "${_out}" '^wasm-pack$')" "a failed tool emits no binary"
  t_assert_contains "${_out}" "rc=0"
done

t_case "the producer loads the MOUNTED 01-core, and refuses a missing file"
_out="$(_wlt 'wlt_fx_core "${SB}/core"; WLT_CORE_DIR="${SB}/core"; wlt_produce "${SB}/o" >/dev/null; echo "FROM=${CROSS_ENV_FROM-}"')"
t_assert_contains "${_out}" "FROM=fixture"
_out="$(_produce 'rm "${SB}/core/cross-meson.sh"')"
t_assert_contains "${_out}" "cross-meson.sh is not mounted"
t_assert_contains "${_out}" "rc=1"
_code="$(grep -v '^[[:space:]]*#' "${LIB}")"
t_assert_eq 0 "$(_count "${_code}" '/opt/scripts\|source_module')" \
  "android-sdk's /opt/scripts/core is an older 01-core; a lookup there loads stale code"

t_case "the entry point: usage errors exit 2"
t_assert_eq 2 "$(t_rc bash "${LIB}")"
t_assert_eq 2 "$(t_rc bash "${LIB}" produce)"

# ---- 7. drift: the RVV flags are cross-env.sh's ----------------------------------------
t_case "wlt_rustflags is what cross-env.sh exports, per arch"

for _a in riscv64 arm64 amd64; do
  _real_flags="$(bash -c 'source "$1/cross-env.sh"
    declare -A e=([rust_target]=x [target_arch]="$2" [rust_env]=X); CC=/cc AR=/ar; unset RUSTFLAGS
    TARGET_ARCH="$2" _export_cargo_vars e >/dev/null 2>&1; printf "%s" "${RUSTFLAGS:-}"' _ "${SCRIPTS}/01-core" "${_a}")"
  t_assert_eq "${_real_flags}" "$(bash -c 'source "$1"; wlt_rustflags "$2"' _ "${LIB}" "${_a}")" \
    "${_a}: the consumer would expect a key the producer never writes"
done

# ---- 8. the closure: android mounts exactly what the producer loads ----------------------
_stage() { awk -v s="$2" '$0 ~ "^FROM .* AS " s "$" {p=1; next} p && /^FROM / {exit} p' "$1"; }
_producer="$(_stage "${DF_ANDROID}" web-lane-tools)"
_mounted="$(printf '%s\n' "${_producer}" | grep -o 'source=linux/scripts/01-core/[a-z-]*\.sh,target=/tmp/wlt/01-core/[a-z-]*\.sh' \
  | sed 's#.*/##' | LC_ALL=C sort | tr '\n' ' ')"
_traced() {  # every file cross-env.sh reaches through its own-directory source lines
  local -a todo=(cross-env.sh) seen=()
  local f n
  while [ "${#todo[@]}" -gt 0 ]; do
    f="${todo[0]}"; todo=("${todo[@]:1}")
    case " ${seen[*]} " in *" ${f} "*) continue ;; esac
    seen+=("${f}")
    for n in $(grep -oE '_DIR\}/[a-z-]+\.sh' "${SCRIPTS}/01-core/${f}" | sed 's#.*/##'); do todo+=("${n}"); done
  done
  printf '%s\n' "${seen[@]}" | LC_ALL=C sort | tr '\n' ' '
}

t_case "Dockerfile.android mounts exactly cross-env.sh's closure, which is WLT_CORE_FILES"
t_assert_eq "$(_traced)" "${_mounted}" "a file cross-env.sh sources but android does not mount resolves to the stale copy"
t_assert_eq "$(_traced)" "$(bash -c 'source "$1"; printf "%s\n" ${WLT_CORE_FILES}' _ "${LIB}" | LC_ALL=C sort | tr '\n' ' ')"
t_assert_contains "${_producer}" "target=/tmp/wlt/06-packaging/web-lane-tools.sh" "so ../01-core is the mounted copy"

t_case "the producer runs before the GCC swap, and its output lands after it"
t_assert_contains "$(grep -e '^FROM .* AS web-lane-tools$' "${DF_ANDROID}")" "FROM android-sdk AS web-lane-tools" \
  "after final's swap the amd64-hosted cross GCC is gone"
_final="$(_stage "${DF_ANDROID}" final)"
t_assert_eq "COPY --link --from=web-lane-tools /opt/web-lane-tools /opt/web-lane-tools" \
  "$(printf '%s\n' "${_final}" | grep -e '^\(RUN\|COPY\)' | tail -n 1)" \
  "above the swap, every producer change re-runs a prefix-sized copy"
t_assert_eq 1 "$(grep -c 'bash /opt/scripts/packaging/swap-native-gcc.sh' "${DF_ANDROID}")" "the swap runs once"
t_assert_contains "${_final}" "bash /opt/scripts/packaging/swap-native-gcc.sh" "and it runs in final"
t_assert_contains "${_producer}" "id=cargo-registry-web-lane-tools-\${TARGET_ARCH},sharing=locked"
for _pin in WASM_PACK_VERSION FLUTTER_RUST_BRIDGE_VERSION; do
  t_assert_eq "$(grep -m1 -e "^ARG ${_pin}=" "${DF_PACKAGE}")" "$(printf '%s\n' "${_producer}" | grep -m1 -e "^ARG ${_pin}=")" \
    "a manual build's producer and consumer default to the same pin, or every key mismatches"
done

# ---- 9. package wiring and the operator switch ------------------------------------------
t_case "Dockerfile defaults are the library's defaults"
t_assert_contains "${_code}" '${WEB_LANE_TOOLS_SOURCE:-auto}'
t_assert_eq 1 "$(grep -c '^ARG WEB_LANE_TOOLS_SOURCE=auto$' "${DF_PACKAGE}")"
t_assert_contains "${_code}" '${WEB_LANE_TOOLS_CACHE:-on}'
t_assert_eq 1 "$(grep -c '^ARG WEB_LANE_TOOLS_CACHE=on$' "${DF_PACKAGE}")"
t_assert_contains "${_code}" '${WEB_LANE_TOOLS_CROSS_ARCHES:-riscv64}'
t_assert_contains "${_producer}" "ARG WEB_LANE_TOOLS_CROSS_ARCHES=riscv64"

t_case "the setup RUN mounts the library, the artifact and the cache where the library looks"
_setup_run="$(awk '/^ARG WEB_LANE_TOOLS_CACHE=/ {p=1} p {print} p && /setup-package-image.sh$/ {exit}' "${DF_PACKAGE}")"
t_assert_contains "${_setup_run}" "source=linux/scripts/06-packaging/web-lane-tools.sh,target=/tmp/wlt/web-lane-tools.sh,ro"
t_assert_contains "${_setup_run}" "from=web-lane-tools-src,source=/opt/web-lane-tools,target=$(bash -c 'source "$1"; printf %s "${WLT_ARTIFACT_DIR}"' _ "${LIB}"),ro"
t_assert_contains "${_setup_run}" "target=$(bash -c 'source "$1"; printf %s "${WLT_CACHE_DIR}"' _ "${LIB}"),id=web-lane-tools-bin-\${TARGETARCH}"
t_assert_contains "$(grep -e 'source /tmp/wlt/web-lane-tools.sh' "${SCRIPTS}/06-packaging/setup-package-image.sh")" \
  "source /tmp/wlt/web-lane-tools.sh" "setup-package-image.sh loads the mount, not a copy"

t_case "one environment switch reaches both stages, and only when set"
_fwd() {  # the build args an orchestrator hands every stage: their count, then the WEB_LANE ones
  t_stage_build_args "$(cd "${SCRIPTS}/../.." && pwd)" riscv64 | grep -e '^ARGS=' -e WEB_LANE || true
}
_on="$(WEB_LANE_TOOLS_SOURCE=native WEB_LANE_TOOLS_CACHE=refresh WEB_LANE_TOOLS_CROSS_ARCHES=none _fwd)"
t_assert_contains "${_on}" "WEB_LANE_TOOLS_SOURCE=native" "WEB_LANE_TOOLS_SOURCE=native must reach the package stage"
t_assert_contains "${_on}" "WEB_LANE_TOOLS_CACHE=refresh"
t_assert_contains "${_on}" "WEB_LANE_TOOLS_CROSS_ARCHES=none" "and the android producer"
_off="$(unset WEB_LANE_TOOLS_SOURCE WEB_LANE_TOOLS_CACHE WEB_LANE_TOOLS_CROSS_ARCHES; _fwd)"
t_assert_ok test "$(printf '%s\n' "${_off}" | sed -n 's/^ARGS=//p')" -gt 100
t_assert_eq 0 "$(_count "${_off}" WEB_LANE)" "unset, the Dockerfile default decides and no key moves"
t_assert_eq 0 "$(grep -c '^WEB_LANE_TOOLS_' "${SCRIPTS}/01-core/versions.env")" \
  "once versions.env carries them, delete the lib-orchestrator.sh line"

t_summary
