#!/usr/bin/env bash
# web-lane-fixtures.sh -- stubs for the suites that drive 06-packaging/web-lane-tools.sh
# off-target (test-web-lane-tools.sh, test-setup-package-image.sh). Not a suite itself:
# run-tests.sh discovers test-*.sh only. Nothing here reaches a network or a toolchain.
_WLT_FX_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/web-lane-fixtures.sh"

# wlt_fx_bin <path> <tool> <version> [fact=value...]: a fake built tool. It answers
# --version, and carries the ELF facts the readelf stub reports for its bytes, so a
# copy keeps them. Facts: arch class machine flags interp needed glibc (default: healthy).
wlt_fx_bin() {
  local path="$1" tool="$2" version="$3" kv
  shift 3
  mkdir -p "$(dirname "${path}")"
  {
    printf '#!/bin/sh\n'
    for kv in "$@"; do printf '# elf-%s\n' "${kv}"; done
    printf 'printf "%%s\\n" "%s %s"\n' "${tool}" "${version}"
  } > "${path}"
  chmod +x "${path}"
}

_wlt_fx_fact() {  # <file> <fact> <default>
  local v
  v="$(sed -n "/^# elf-$2=/{s///p;q}" "$1")"
  printf '%s' "${v:-$3}"
}

# readelf as the gate calls it (-h, -l, -d or -V, plus -W), answering from the file's facts.
readelf() {
  local f="" a opt="" m fl ld so
  for a in "$@"; do
    case "${a}" in -h|-l|-d|-V) opt="${a}" ;; -*) ;; *) f="${a}" ;; esac
  done
  [ -f "${f}" ] || return 1
  case "$(_wlt_fx_fact "${f}" arch riscv64)" in
    amd64) m="Advanced Micro Devices X86-64"; fl=0x0; ld=/lib64/ld-linux-x86-64.so.2 ;;
    arm64) m=AArch64; fl=0x0; ld=/lib/ld-linux-aarch64.so.1 ;;
    *) m=RISC-V; fl="0x5, RVC, double-float ABI"; ld=/lib/ld-linux-riscv64-lp64d.so.1 ;;
  esac
  case "${opt}" in
    -h) printf '  Class:                             %s\n' "$(_wlt_fx_fact "${f}" class ELF64)"
        printf '  Machine:                           %s\n' "$(_wlt_fx_fact "${f}" machine "${m}")"
        printf '  Flags:                             %s\n' "$(_wlt_fx_fact "${f}" flags "${fl}")" ;;
    -l) printf '      [Requesting program interpreter: %s]\n' "$(_wlt_fx_fact "${f}" interp "${ld}")" ;;
    -d) for so in $(_wlt_fx_fact "${f}" needed "libc.so.6 libm.so.6 libgcc_s.so.1"); do
          printf ' 0x0000000000000001 (NEEDED)             Shared library: [%s]\n' "${so}"
        done ;;
    -V) printf '  0x0010:   Name: GLIBC_2.17  Flags: none  Version: 3\n'
        printf '  0x0020:   Name: GLIBC_%s  Flags: none  Version: 4\n' "$(_wlt_fx_fact "${f}" glibc 2.39)" ;;
  esac
  return 0
}

getconf() { printf 'glibc %s\n' "${FAKE_GLIBC-2.43}"; }
dpkg() { printf '%s\n' "${FAKE_BUILD_ARCH-amd64}"; }
dpkg-query() { printf '%s' "${FAKE_SYSROOT_GLIBC-2.43-2ubuntu2cross1}"; }

# The cargo a fake CARGO_HOME runs: records argv and the build env, then (FAKE_CARGO_RC=0)
# leaves <--root>/bin/<tool> for TARGET_ARCH, with FAKE_BUILD_FACTS (';'-separated facts).
_wlt_fx_cargo() {
  local root="" tool="" ver="" rc="${FAKE_CARGO_RC-0}"
  local -a facts=()
  printf 'CARGO %s\n' "$*"
  printf 'CARGO_ENV target_dir=%s bzip2=%s lzma=%s zstd=%s wrapper=[%s] rustflags=[%s]\n' \
    "${CARGO_TARGET_DIR-unset}" "${BZIP2_NO_PKG_CONFIG-unset}" "${LZMA_API_STATIC-unset}" \
    "${ZSTD_SYS_USE_PKG_CONFIG-unset}" "${RUSTC_WRAPPER-unset}" "${RUSTFLAGS-}"
  if [ "${rc}" != 0 ]; then echo "error: could not compile (fake)"; return "${rc}"; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) root="$2"; shift 2 ;;
      --version) ver="$2"; shift 2 ;;
      --target) shift 2 ;;
      install|--locked) shift ;;
      *) tool="$1"; shift ;;
    esac
  done
  IFS=';' read -r -a facts <<< "${FAKE_BUILD_FACTS-}"
  wlt_fx_bin "${root}/bin/${tool}" "${tool}" "${FAKE_BIN_VERSION-${ver}}" \
    "arch=${TARGET_ARCH:-riscv64}" "${facts[@]}"
}

# wlt_fx_home <dir>: a CARGO_HOME whose rustup/rustc/cargo are recorders (FAKE_RUSTUP_RC,
# FAKE_RUSTC, and _wlt_fx_cargo above).
wlt_fx_home() {
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\nprintf "RUSTUP %%s\\n" "$*"\nexit "${FAKE_RUSTUP_RC-0}"\n' > "$1/bin/rustup"
  printf '#!/usr/bin/env bash\nprintf "rustc %%s (fake 2026-01-01)\\n" "${FAKE_RUSTC-1.98.1}"\n' > "$1/bin/rustc"
  printf '#!/usr/bin/env bash\nsource %q\n%s "$@"\n' "${_WLT_FX_SELF}" _wlt_fx_cargo > "$1/bin/cargo"
  chmod +x "$1/bin/rustup" "$1/bin/rustc" "$1/bin/cargo"
}

# wlt_fx_artifact <tool> <version> <arch> [fact=value...]: a status=ok producer output
# under WLT_ARTIFACT_DIR, keyed the way the producer keys it (needs the library loaded).
wlt_fx_artifact() {
  local tool="$1" version="$2" arch="$3" dir keytext
  shift 3
  dir="${WLT_ARTIFACT_DIR}/$(rust_target_triple_for_arch "${arch}")"
  keytext="$(wlt_key_text "${tool}" "${version}" "${dir##*/}" "${FAKE_RUSTC-1.98.1}" "$(wlt_rustflags "${arch}")")"
  wlt_fx_bin "${dir}/bin/${tool}" "${tool}" "${version}" "arch=${arch}" "$@"
  wlt_manifest_write "${dir}/${tool}.manifest" "${keytext}" "key=$(wlt_key "${keytext}")" \
    "sha256=$(wlt_sha256 "${dir}/bin/${tool}")" status=ok built_by=cross:amd64
}

# wlt_fx_core <dir>: a producer 01-core -- the real platform.sh, a cross-env.sh whose
# setup_linux_cross_env exports FAKE_CROSS_RUSTFLAGS (or fails, FAKE_CROSS_ENV_RC).
wlt_fx_core() {
  local f
  mkdir -p "$1"
  for f in ubuntu-mirror.sh cross-gcc.sh cross-python.sh cross-apt.sh cross-meson.sh; do : > "$1/${f}"; done
  cp "$(dirname "${_WLT_FX_SELF}")/../01-core/platform.sh" "$1/platform.sh"
  cat > "$1/cross-env.sh" <<'CROSSENV'
source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"
setup_linux_cross_env() {
  [ "${FAKE_CROSS_ENV_RC-0}" = 0 ] || return "${FAKE_CROSS_ENV_RC}"
  export RUSTFLAGS="${FAKE_CROSS_RUSTFLAGS--C target-feature=+v,+zvl128b}"
  export CARGO_TARGET_DIR=/opt/cargo-target/riscv64 RUSTC_WRAPPER=/usr/bin/sccache
  export CROSS_ENV_FROM=fixture
}
CROSSENV
}
