#!/usr/bin/env bash
# web-lane-tools.sh -- wasm-pack and flutter_rust_bridge_codegen built from source, for
# the arch upstream publishes no binary for. Sourced by setup-package-image.sh (sets no
# shell options); `bash web-lane-tools.sh produce <out>` is Dockerfile.android's cross
# producer. docs/consumer-image-contract.md#building-the-web-lane-tools-from-source

: "${WLT_ARTIFACT_DIR:=/tmp/wlt/artifact}"
: "${WLT_CACHE_DIR:=/root/.cache/web-lane-tools}"
: "${WLT_PROVENANCE:=/usr/local/share/web-lane-tools/provenance}"
: "${WLT_CORE_DIR:=}"
WLT_KEY_SCHEMA=1
WLT_C_ENV_KEY='BZIP2_NO_PKG_CONFIG=1 LZMA_API_STATIC=1 -ZSTD_SYS_USE_PKG_CONFIG'
WLT_CARGO_ARGS='--locked'
WLT_NEEDED_OK='libc.so.6 libm.so.6 libgcc_s.so.1 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1'
_WLT_WHY=""

# The Rust vector flags cross-env.sh sets for riscv64; test-web-lane-tools.sh pins the copy.
wlt_rustflags() {
  case "$1" in
    riscv64) printf '%s' '-C target-feature=+v,+zvl128b' ;;
    *) ;;
  esac
  return 0
}

# Vendored static bzip2/xz/zstd: under PKG_CONFIG_ALLOW_CROSS the -sys crates link the
# BUILD host's .so. WLT_C_ENV_KEY is this function written as key text.
wlt_c_env() {
  export BZIP2_NO_PKG_CONFIG=1 LZMA_API_STATIC=1
  unset ZSTD_SYS_USE_PKG_CONFIG
  return 0
}

wlt_loader() {
  case "$1" in
    amd64) printf '%s' /lib64/ld-linux-x86-64.so.2 ;;
    arm64) printf '%s' /lib/ld-linux-aarch64.so.1 ;;
    riscv64) printf '%s' /lib/ld-linux-riscv64-lp64d.so.1 ;;
    *) return 1 ;;
  esac
  return 0
}

# wlt_key_text <tool> <version> <triple> <rustc-release> <rustflags>: everything the bytes
# depend on. Who built it (cross or native) is recorded in the manifest, never keyed.
wlt_key_text() {
  printf 'schema=%s\ntool=%s\nversion=%s\ntarget=%s\nrustc=%s\nrustflags=%s\nc_env=%s\ncargo_args=%s\n' \
    "${WLT_KEY_SCHEMA}" "$1" "$2" "$3" "$4" "$5" "${WLT_C_ENV_KEY}" "${WLT_CARGO_ARGS}"
}

wlt_key() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

_wlt_kt() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }  # <keytext> <field>

# wlt_cache_entry <keytext> -> <WLT_CACHE_DIR>/<tool>-<version>_rust-<rustc>_<target>_<key12>
wlt_cache_entry() {
  local key
  key="$(wlt_key "$1")"
  printf '%s/%s-%s_rust-%s_%s_%s' "${WLT_CACHE_DIR}" "$(_wlt_kt "$1" tool)" "$(_wlt_kt "$1" version)" \
    "$(_wlt_kt "$1" rustc)" "$(_wlt_kt "$1" target)" "${key:0:12}"
}

wlt_sha256() { { sha256sum "$1" 2>/dev/null || true; } | cut -d' ' -f1; }

# wlt_manifest_get <file> <field>: the first <field>=value, empty when absent.
wlt_manifest_get() {
  [ -r "$1" ] || return 0
  awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
}

# wlt_manifest_write <file> <keytext|""> <field=value>...
wlt_manifest_write() {
  local file="$1" keytext="$2"
  shift 2
  {
    if [ -n "${keytext}" ]; then printf '%s\n' "${keytext}"; fi
    printf '%s\n' "$@"
  } > "${file}"
}

# The key text a manifest opens with (its first eight lines).
_wlt_manifest_key_text() { sed -n '1,8p' "$1" 2>/dev/null || true; }

wlt_rustc_release() {
  local v
  v="$("${CARGO_HOME:-/usr/local/cargo}/bin/rustc" -V 2>/dev/null || true)"
  v="${v#rustc }"
  printf '%s' "${v%% *}"
}

wlt_glibc_ceiling() {
  local v
  v="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
  v="${v##* }"
  if [ -z "${v}" ]; then
    echo "ERROR: web-lane: getconf GNU_LIBC_VERSION reports nothing; the tools' GLIBC cannot be bounded" >&2
    return 1
  fi
  printf '%s' "${v}"
}

# Highest GLIBC_x.y a binary needs, from its version-needs table.
wlt_max_glibc() {
  { LC_ALL=C readelf -V -W "$1" 2>/dev/null || true; } \
    | { grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' || true; } | sed 's/^GLIBC_//' | sort -V | tail -n 1
}

_wlt_why() { _WLT_WHY="$1 (${2:-none} vs $3)"; }

_wlt_field() {  # <readelf -h text> <field> -> the value after "<field>:"
  local v
  v="$(printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p")"
  printf '%s' "${v%%$'\n'*}"
}

# ELF64, the arch's machine, and on riscv64 the lp64d float ABI.
_wlt_gate_header() {  # <file> <arch>
  local hdr machine got
  hdr="$(LC_ALL=C readelf -h "$1" 2>/dev/null || true)"
  got="$(_wlt_field "${hdr}" Class)"
  [ "${got}" = ELF64 ] || { _wlt_why "ELF class" "${got}" ELF64; return 1; }
  machine="$(arch_elf_machine_grep_for "$2")" || { _wlt_why "arch" "$2" "amd64, arm64 or riscv64"; return 1; }
  got="$(_wlt_field "${hdr}" Machine)"
  case "${got}" in
    *"${machine}"*) ;;
    *) _wlt_why "ELF machine" "${got}" "${machine}"; return 1 ;;
  esac
  [ "$2" = riscv64 ] || return 0
  got="$(_wlt_field "${hdr}" Flags)"
  case "${got}" in
    *"double-float ABI"*) return 0 ;;
    *) _wlt_why "riscv64 float ABI" "${got}" "double-float ABI (lp64d)"; return 1 ;;
  esac
}

# glibc's loader for the arch, and nothing NEEDED beyond libc's own family.
_wlt_gate_loader() {  # <file> <arch>
  local loader interp so
  loader="$(wlt_loader "$2")"
  interp="$({ LC_ALL=C readelf -l -W "$1" 2>/dev/null || true; } | sed -n 's/.*program interpreter: \(.*\)\]$/\1/p')"
  [ "${interp}" = "${loader}" ] || { _wlt_why "PT_INTERP" "${interp}" "${loader}"; return 1; }
  while IFS= read -r so; do
    case " ${WLT_NEEDED_OK} ${loader##*/} " in
      *" ${so} "*) ;;
      *) _wlt_why "NEEDED" "${so}" "only ${WLT_NEEDED_OK} and the loader"; return 1 ;;
    esac
  done < <({ LC_ALL=C readelf -d -W "$1" 2>/dev/null || true; } | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
  return 0
}

_wlt_gate_glibc() {  # <file> <ceiling>: no GLIBC_ symbol version above what the image has
  local max
  max="$(wlt_max_glibc "$1")"
  if [ -z "${max}" ]; then
    _wlt_why "GLIBC version needs" "" "at least one GLIBC_ entry"
    return 1
  fi
  [ "$(printf '%s\n%s\n' "${max}" "$2" | sort -V | tail -n 1)" = "$2" ] || { _wlt_why "max GLIBC" "${max}" "<= $2"; return 1; }
  return 0
}

_wlt_gate_exec() {
  local tool="$1" file="$2" version="$3" out
  out="$(timeout 120 "${file}" --version 2>&1 || true)"
  out="${out%%$'\n'*}"
  [ "${out}" = "${tool} ${version}" ] || { _wlt_why "--version" "${out}" "${tool} ${version}"; return 1; }
  return 0
}

# wlt_assert_binary <tool> <file> <arch> [glibc-ceiling] [version]: the gate every
# from-source binary passes; with <version> it also runs `<file> --version`. On failure
# _WLT_WHY names what and why. Not covered: behaviour beyond --version, a consistently
# forged binary+manifest pair (the trust boundary of every cachemount), C++ deps.
wlt_assert_binary() {
  local tool="$1" file="$2" arch="$3" ceiling="${4:-}" version="${5:-}"
  _WLT_WHY=""
  command -v readelf >/dev/null 2>&1 || { _wlt_why "readelf" "" "binutils on PATH"; return 1; }
  [ -f "${file}" ] || { _wlt_why "binary" "" "${file}"; return 1; }
  _wlt_gate_header "${file}" "${arch}" || return 1
  _wlt_gate_loader "${file}" "${arch}" || return 1
  if [ -n "${ceiling}" ]; then
    _wlt_gate_glibc "${file}" "${ceiling}" || return 1
  fi
  if [ -n "${version}" ]; then
    _wlt_gate_exec "${tool}" "${file}" "${version}" || return 1
  fi
  return 0
}

# Stage <src> at <dest> and gate the staged bytes: its sha256 against <want> ("-" when
# nothing is claimed), then wlt_assert_binary. <version> empty skips the --version run.
_wlt_verify() {
  local tool="$1" version="$2" arch="$3" ceiling="$4" src="$5" want="$6" dest="$7" got
  rm -f "${dest}"
  if ! cp "${src}" "${dest}" 2>/dev/null; then _wlt_why "binary" "" "${src}"; return 1; fi
  chmod 0755 "${dest}"
  if [ "${want}" != - ]; then
    got="$(wlt_sha256 "${dest}")"
    [ "${got}" = "${want}" ] || { _wlt_why "sha256" "${got}" "${want:-a recorded sha256}"; return 1; }
  fi
  wlt_assert_binary "${tool}" "${dest}" "${arch}" "${ceiling}" "${version}" || return 1
  return 0
}

# wlt_cache_lookup <tool> <version|""> <arch> <ceiling> <keytext> <entry> <dest>: a verified
# hit is staged at <dest>. Any other entry is deleted with a WARN, and the caller rebuilds.
wlt_cache_lookup() {
  local tool="$1" version="$2" arch="$3" ceiling="$4" keytext="$5" entry="$6" dest="$7" why=""
  if [ ! -d "${entry}" ]; then
    echo "NOTE: web-lane ${tool}: cache MISS ${entry##*/}"
    return 1
  fi
  if [ "$(_wlt_manifest_key_text "${entry}/manifest")" != "${keytext}" ]; then
    why="its key text is not this build's"
  elif ! _wlt_verify "${tool}" "${version}" "${arch}" "${ceiling}" "${entry}/${tool}" \
         "$(wlt_manifest_get "${entry}/manifest" sha256)" "${dest}"; then
    why="${_WLT_WHY}"
  fi
  if [ -n "${why}" ]; then
    echo "WARN: web-lane cache entry ${entry##*/} rejected: ${why}; rebuilding"
    rm -rf "${entry}"
    return 1
  fi
  echo "OK: web-lane ${tool}: cache HIT ${entry##*/}"
  return 0
}

_wlt_cache_trim() {  # <tool>: keep the newest three entries
  local tool="$1" d n=0
  while IFS= read -r d; do
    n=$((n + 1))
    if [ "${n}" -gt 3 ]; then rm -rf "${d}"; fi
  done < <(find "${WLT_CACHE_DIR}" -mindepth 1 -maxdepth 1 -type d -name "${tool}-*_rust-*" \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  return 0
}

# wlt_cache_store <tool> <entry> <keytext> <binary> <built-by>: written beside the entry,
# then renamed into place, so a failed store leaves nothing visible. Never fails the build.
wlt_cache_store() {
  local tool="$1" entry="$2" keytext="$3" bin="$4" built_by="$5" tmp
  tmp="${WLT_CACHE_DIR}/.tmp.$$.${tool}"
  rm -rf "${tmp}"
  if mkdir -p "${tmp}" && cp "${bin}" "${tmp}/${tool}" \
     && wlt_manifest_write "${tmp}/manifest" "${keytext}" "key=$(wlt_key "${keytext}")" \
          "sha256=$(wlt_sha256 "${bin}")" status=ok "built_by=${built_by}" \
     && rm -rf "${entry}" && mv -T "${tmp}" "${entry}"; then
    _wlt_cache_trim "${tool}"
    echo "OK: web-lane ${tool}: cached as ${entry##*/}"
    return 0
  fi
  rm -rf "${tmp}"
  echo "WARN: web-lane ${tool}: the cache store failed; the next build of this key recompiles"
  return 0
}

wlt_validate_knobs() {
  case "${WEB_LANE_TOOLS_SOURCE:-auto}" in
    auto|cross|native|legacy) ;;
    *) echo "ERROR: WEB_LANE_TOOLS_SOURCE='${WEB_LANE_TOOLS_SOURCE}' (want auto, cross, native or legacy)" >&2; return 1 ;;
  esac
  case "${WEB_LANE_TOOLS_CACHE:-on}" in
    on|refresh|off) ;;
    *) echo "ERROR: WEB_LANE_TOOLS_CACHE='${WEB_LANE_TOOLS_CACHE}' (want on, refresh or off)" >&2; return 1 ;;
  esac
  return 0
}

_wlt_install() {  # <tool> <version> <cross|cache|native> <binary> <key>
  local tool="$1" version="$2" source="$3" bin="$4" key="$5" from
  if ! install -m 0755 "${bin}" "${CARGO_HOME:-/usr/local/cargo}/bin/${tool}"; then
    echo "ERROR: web-lane ${tool}: install into ${CARGO_HOME:-/usr/local/cargo}/bin failed" >&2
    return 1
  fi
  mkdir -p "${WLT_PROVENANCE%/*}" && printf 'tool=%s version=%s source=%s sha256=%s key=%s\n' \
    "${tool}" "${version}" "${source}" "$(wlt_sha256 "${bin}")" "${key}" >> "${WLT_PROVENANCE}" || return 1
  case "${source}" in
    cross) from="the cross-built artifact" ;;
    cache) from="the web-lane cache" ;;
    *) from="a native build" ;;
  esac
  echo "OK: ${tool} ${version} installed from ${from} (key ${key:0:12})"
  return 0
}

# auto: WARN and build natively (returns 2). cross: the artifact was required (returns 1).
_wlt_unusable() {  # <mode> <tool> <why>
  if [ "$1" = cross ]; then
    echo "ERROR: web-lane $2: WEB_LANE_TOOLS_SOURCE=cross, but $3" >&2
    return 1
  fi
  echo "WARN: web-lane $2: $3; building natively instead (the cross fast path was not taken)"
  return 2
}

# 0 installed, 1 a defect, 2 not usable here: build natively. <keytext> is the cross key.
_wlt_from_artifact() {  # <mode> <keytext> <arch> <ceiling> <work>
  local mode="$1" keytext="$2" arch="$3" ceiling="$4" work="$5" tool version dir status reason
  tool="$(_wlt_kt "${keytext}" tool)"
  version="$(_wlt_kt "${keytext}" version)"
  dir="${WLT_ARTIFACT_DIR}/$(_wlt_kt "${keytext}" target)"
  status="$(wlt_manifest_get "${dir}/${tool}.manifest" status)"
  reason="$(wlt_manifest_get "${dir}/${tool}.manifest" reason)"
  if [ "${status}" = skipped ]; then
    echo "NOTE: web-lane ${tool}: the cross producer skipped ${arch} (${reason}); building natively"
    return 2
  fi
  if [ "${status}" != ok ]; then
    _wlt_unusable "${mode}" "${tool}" "the cross artifact is ${status:-absent}${reason:+ (${reason})}" || return $?
  fi
  if [ "$(_wlt_manifest_key_text "${dir}/${tool}.manifest")" != "${keytext}" ]; then
    _wlt_unusable "${mode}" "${tool}" "the cross artifact was built for another key (pin or toolchain skew)" || return $?
  fi
  # status=ok and this key: from here every failure is a defect, in auto and cross alike.
  if ! _wlt_verify "${tool}" "${version}" "${arch}" "${ceiling}" "${dir}/bin/${tool}" \
       "$(wlt_manifest_get "${dir}/${tool}.manifest" sha256)" "${work}/${tool}"; then
    echo "ERROR: web-lane ${tool}: the cross artifact claims status=ok, but ${_WLT_WHY}" >&2
    return 1
  fi
  _wlt_install "${tool}" "${version}" cross "${work}/${tool}" "$(wlt_key "${keytext}")"
}

# The native build: rv64gc Rust and vendored C, into a scratch root so the gate sees it first.
_wlt_cargo_native() {  # <tool> <version> <root>
  (
    unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_RUSTFLAGS
    wlt_c_env
    "${CARGO_HOME:-/usr/local/cargo}/bin/cargo" install --locked "$1" --version "$2" --root "$3"
  )
}

# <keytext> is the native key: no RUSTFLAGS, so a native build stays rv64gc Rust.
_wlt_native() {  # <keytext> <arch> <ceiling> <work>
  local keytext="$1" arch="$2" ceiling="$3" work="$4" cache="${WEB_LANE_TOOLS_CACHE:-on}" tool version key entry
  tool="$(_wlt_kt "${keytext}" tool)"
  version="$(_wlt_kt "${keytext}" version)"
  key="$(wlt_key "${keytext}")"
  entry="$(wlt_cache_entry "${keytext}")"
  if [ "${cache}" = on ] \
     && wlt_cache_lookup "${tool}" "${version}" "${arch}" "${ceiling}" "${keytext}" "${entry}" "${work}/${tool}"; then
    _wlt_install "${tool}" "${version}" cache "${work}/${tool}" "${key}" || return 1
    return 0
  fi
  if ! _wlt_cargo_native "${tool}" "${version}" "${work}/root"; then
    echo "WARN: cargo install ${tool} ${version} failed; the web lane will build it per run"
    return 0
  fi
  if ! _wlt_verify "${tool}" "${version}" "${arch}" "${ceiling}" "${work}/root/bin/${tool}" - "${work}/${tool}"; then
    echo "ERROR: web-lane ${tool}: cargo reported success, but the native build fails ${_WLT_WHY}" >&2
    return 1
  fi
  if [ "${cache}" != off ]; then
    wlt_cache_store "${tool}" "${entry}" "${keytext}" "${work}/${tool}" "native:${arch}"
  fi
  _wlt_install "${tool}" "${version}" native "${work}/${tool}" "${key}"
}

# legacy: the pre-2026-09-23 leg, verbatim. cargo installs into CARGO_HOME itself (.crates.toml
# kept) in the stage's own env: no gate, cache or provenance, and a failure only WARNs.
_wlt_legacy() {  # <tool> <version>
  if "${CARGO_HOME:-/usr/local/cargo}/bin/cargo" install --locked "$1" --version "$2"; then
    echo "OK: $1 $2 installed"
    return 0
  fi
  echo "WARN: cargo install $1 $2 failed; the web lane will build it per run"
  return 0
}

# wlt_install_from_source <tool> <version>: install_web_lane_toolchain's from-source leg.
# Returns 1 only for a defect (a bad knob, a binary that claims to be good and is not, an
# image that cannot bound or install it) or for cross without a provable artifact.
wlt_install_from_source() {
  local tool="$1" version="$2" mode="${WEB_LANE_TOOLS_SOURCE:-auto}" arch triple rustc ceiling work rc=2
  wlt_validate_knobs || return 1
  if [ "${mode}" = legacy ]; then
    _wlt_legacy "${tool}" "${version}"
    return
  fi
  arch="$(arch_oci)"
  if ! triple="$(rust_target_triple_for_arch "${arch}")"; then
    echo "ERROR: web-lane ${tool}: no Rust triple for this image's arch '${arch}'" >&2
    return 1
  fi
  rustc="$(wlt_rustc_release)"
  if [ -z "${rustc}" ]; then
    # Under cross an expected artifact cannot be keyed, so it cannot be proven.
    if [ "${mode}" = cross ] && [ "$(wlt_manifest_get "${WLT_ARTIFACT_DIR}/${triple}/${tool}.manifest" status)" != skipped ]; then
      echo "ERROR: web-lane ${tool}: WEB_LANE_TOOLS_SOURCE=cross, but rustc -V reports no release to key the artifact by" >&2
      return 1
    fi
    echo "WARN: web-lane ${tool}: rustc -V reports no release; the web lane will build it per run"
    return 0
  fi
  ceiling="$(wlt_glibc_ceiling)" || return 1
  work="$(mktemp -d)" || return 1
  if [ "${mode}" != native ]; then
    rc=0
    _wlt_from_artifact "${mode}" "$(wlt_key_text "${tool}" "${version}" "${triple}" "${rustc}" "$(wlt_rustflags "${arch}")")" \
      "${arch}" "${ceiling}" "${work}" || rc=$?
  fi
  if [ "${rc}" -eq 2 ]; then
    rc=0
    _wlt_native "$(wlt_key_text "${tool}" "${version}" "${triple}" "${rustc}" "")" "${arch}" "${ceiling}" "${work}" || rc=$?
  fi
  rm -rf "${work}"
  return "${rc}"
}

# ---- the producer (Dockerfile.android, stage web-lane-tools) -------------------------

wlt_validate_cross_arches() {
  local list="$1" a
  local -a arches=()
  [ "${list}" != none ] || return 0
  IFS=',' read -r -a arches <<< "${list}"
  [ "${#arches[@]}" -gt 0 ] || arches=("")
  for a in "${arches[@]}"; do
    case "${a}" in
      amd64|arm64|riscv64) ;;
      *) echo "ERROR: WEB_LANE_TOOLS_CROSS_ARCHES='${list}' (want a comma list of amd64, arm64, riscv64, or none)" >&2; return 1 ;;
    esac
  done
  return 0
}

_wlt_skip_reason() {  # <target> <build> <list> -> why the producer does not build <target>
  local target="$1" build="$2" list="$3" a
  local -a arches=()
  if [ "${target}" = "${build}" ]; then
    printf 'native-build-platform: this %s builder compiles its own arch natively' "${build}"
    return 0
  fi
  if [ "${list}" = none ]; then
    printf 'disabled: WEB_LANE_TOOLS_CROSS_ARCHES=none'
    return 0
  fi
  IFS=',' read -r -a arches <<< "${list}"
  for a in "${arches[@]}"; do
    [ "${a}" != "${target}" ] || return 0
  done
  printf 'not in WEB_LANE_TOOLS_CROSS_ARCHES=%s' "${list}"
  return 0
}

_wlt_mark() {  # <dir> <tool> <skipped|failed> <reason>
  mkdir -p "$1" || return 1
  wlt_manifest_write "$1/$2.manifest" "" "status=$3" "reason=${4//$'\n'/ }"
}

# The hub's own cross env, minus what would make the key lie.
_wlt_cross_env() {  # <target>
  local want
  unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_RUSTFLAGS
  export BUILD_MODE=cross TARGET_ARCH="$1"
  setup_linux_cross_env || { _WLT_WHY="setup_linux_cross_env failed: no cross toolchain for $1"; return 1; }
  want="$(wlt_rustflags "$1")"
  [ "${RUSTFLAGS:-}" = "${want}" ] || { _wlt_why "RUSTFLAGS drift" "${RUSTFLAGS:-}" "${want}"; return 1; }
  CARGO_TARGET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wlt-target.XXXXXX")" || return 1
  export CARGO_TARGET_DIR RUSTC_WRAPPER="" CARGO_NET_RETRY=5
  wlt_c_env
  return 0
}

_wlt_sysroot_glibc() {  # <target> -> upstream glibc of the cross sysroot, or empty
  local v
  v="$(dpkg-query -W -f='${Version}' "libc6-dev-$1-cross" 2>/dev/null || true)"
  printf '%s' "${v%%-*}"
}

_wlt_cross_build() {  # <tool> <version> <triple> <root>: bounded, so a hung fetch cannot stall android
  local log="$4.log" rc=0 started="${SECONDS}"
  timeout 1800 "${CARGO_HOME:-/usr/local/cargo}/bin/cargo" install --locked --root "$4" \
    --target "$3" "$1" --version "$2" > "${log}" 2>&1 || rc=$?
  cat "${log}" || true
  if [ "${rc}" -ne 0 ]; then
    _WLT_WHY="cargo install exited ${rc}: $(tail -n 1 "${log}" 2>/dev/null || true)"
    return 1
  fi
  echo "OK: web-lane producer: $1 $2 built for $3 in $((SECONDS - started)) s"
  return 0
}

_wlt_produce_one() {  # <tool> <version> <dir> <target> <build>
  local tool="$1" version="$2" dir="$3" target="$4" build="$5"
  local triple rustc keytext entry work ceiling
  _WLT_WHY=""
  if [ -z "${version}" ]; then
    _WLT_WHY="no ${tool} version build-arg reached the android stage"
    return 1
  fi
  triple="$(rust_target_triple_for_arch "${target}")"
  rustc="$(wlt_rustc_release)"
  [ -n "${rustc}" ] || { _WLT_WHY="no rustc release under ${CARGO_HOME:-/usr/local/cargo}"; return 1; }
  keytext="$(wlt_key_text "${tool}" "${version}" "${triple}" "${rustc}" "${RUSTFLAGS:-}")"
  entry="$(wlt_cache_entry "${keytext}")"
  ceiling="$(_wlt_sysroot_glibc "${target}")"
  work="$(mktemp -d "${TMPDIR:-/tmp}/wlt-work.XXXXXX")" || return 1
  if ! wlt_cache_lookup "${tool}" "" "${target}" "${ceiling}" "${keytext}" "${entry}" "${work}/${tool}"; then
    _wlt_cross_build "${tool}" "${version}" "${triple}" "${work}/root" || return 1
    _wlt_verify "${tool}" "" "${target}" "${ceiling}" "${work}/root/bin/${tool}" - "${work}/${tool}" || return 1
    wlt_cache_store "${tool}" "${entry}" "${keytext}" "${work}/${tool}" "cross:${build}"
  fi
  install -D -m 0755 "${work}/${tool}" "${dir}/bin/${tool}" || return 1
  wlt_manifest_write "${dir}/${tool}.manifest" "${keytext}" "key=$(wlt_key "${keytext}")" \
    "sha256=$(wlt_sha256 "${work}/${tool}")" status=ok "built_by=cross:${build}" \
    "max_glibc=$(wlt_max_glibc "${work}/${tool}")" || return 1
  rm -rf "${work}"
  return 0
}

# cross-env.sh and every file it sources: the producer's whole 01-core closure, which
# Dockerfile.android mounts file by file (test-web-lane-tools.sh pins all three lists).
WLT_CORE_FILES='cross-env.sh platform.sh ubuntu-mirror.sh cross-gcc.sh cross-python.sh cross-apt.sh cross-meson.sh'

# By explicit path, never source_module: android-sdk's /opt/scripts/core is an older copy.
_wlt_load_core() {  # <core-dir>
  local f
  local -a files=()
  IFS=' ' read -r -a files <<< "${WLT_CORE_FILES}"
  for f in "${files[@]}"; do
    [ -f "$1/${f}" ] || { echo "ERROR: web-lane producer: $1/${f} is not mounted" >&2; return 1; }
  done
  # shellcheck source=linux/scripts/01-core/cross-env.sh
  source "$1/cross-env.sh" || return 1
  return 0
}

# wlt_produce <out>: only a bad knob or a missing core file fails the android stage; a
# cargo or gate failure is recorded as status=failed and the package stage decides.
wlt_produce() {
  local out="$1" core="${WLT_CORE_DIR}" target build triple list reason="" status=skipped entry tool
  [ -n "${core}" ] || core="$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd || true)"
  _wlt_load_core "${core}" || return 1
  unset BUILDARCH BUILDPLATFORM   # the arch this RUN executes on, not the builder node's
  list="${WEB_LANE_TOOLS_CROSS_ARCHES:-riscv64}"
  wlt_validate_cross_arches "${list}" || return 1
  target="$(arch_oci)"
  build="$(build_arch_oci)"
  if ! triple="$(rust_target_triple_for_arch "${target}")"; then
    echo "ERROR: web-lane producer: no Rust triple for '${target}'" >&2
    return 1
  fi
  mkdir -p "${out}/${triple}"
  reason="$(_wlt_skip_reason "${target}" "${build}" "${list}")"
  if [ -z "${reason}" ] && ! _wlt_cross_env "${target}"; then
    reason="${_WLT_WHY}"
    status=failed
  fi
  for entry in "wasm-pack:${WASM_PACK_VERSION:-}" "flutter_rust_bridge_codegen:${FLUTTER_RUST_BRIDGE_VERSION:-}"; do
    tool="${entry%%:*}"
    if [ -n "${reason}" ]; then
      _wlt_mark "${out}/${triple}" "${tool}" "${status}" "${reason}"
    elif ! _wlt_produce_one "${tool}" "${entry#*:}" "${out}/${triple}" "${target}" "${build}"; then
      echo "WARN: web-lane producer: ${tool} failed (${_WLT_WHY}); the package stage decides"
      _wlt_mark "${out}/${triple}" "${tool}" failed "${_WLT_WHY:-unexpected error}"
    fi
  done
  if [ -n "${reason}" ]; then echo "NOTE: web-lane producer: ${target} ${status}: ${reason}"; fi
  echo "OK: web-lane producer: manifests for ${target} in ${out}/${triple}"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  if [ "${1:-}" != produce ] || [ -z "${2:-}" ]; then
    echo "usage: web-lane-tools.sh produce <out-dir>" >&2
    exit 2
  fi
  wlt_produce "$2"
fi
