#!/usr/bin/env bash
# Stubbed commands and tiny native C programs cover probe policy; no FFmpeg or cross toolchain is built.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
: "${FFMPEG_PROBE_SOURCE:=${TESTS_DIR}/../03-media/build/ffmpeg/ffmpeg-probe-framework.sh}"
# shellcheck source=../03-media/build/ffmpeg/ffmpeg-probe-framework.sh
source "${FFMPEG_PROBE_SOURCE}"
D="$(mktemp -d)"
trap 'rm -rf "${D}"' EXIT
export PROBE_CALLS="${D}/calls" PROBE_SOURCE="${D}/source.c"
cat > "${D}/compiler" <<'COMPILER'
#!/usr/bin/env bash
printf '<%s>' "$@" >> "${PROBE_CALLS}"
printf '\n' >> "${PROBE_CALLS}"
for arg in "$@"; do
  case "${arg}" in *.c) cp "${arg}" "${PROBE_SOURCE}" ;; esac
done
printf 'probe diagnostic\n' >&2
exit "${PROBE_STATUS:-0}"
COMPILER
chmod +x "${D}/compiler"
export CC="${D}/compiler"
cross_build_is_active() {
  [ "${PROBE_CROSS:-0}" = 1 ] && return 0
  return 1
}
ffmpeg_append_cross_search_flags() {
  local -n probe_flags="$1"
  probe_flags+=(-I/target/include -L/target/lib)
}
command() {
  t_command_available_override ld.lld "${PROBE_LLD:-0}" "$@"
}
_reset() { : > "${PROBE_CALLS}"; }
_reset
t_case "compile probes preserve flags, conditions and compile-only mode"
t_assert_eq 0 "$(t_rc ffmpeg_try_cpp_condition 'stdint.h' 'UINT32_MAX > 0' '-DTHING=1 -O2')"
args="$(cat "${PROBE_CALLS}")"
t_assert_contains "${args}" '<-DTHING=1><-O2><-c>'
t_assert_contains "$(cat "${PROBE_SOURCE}")" '#include <stdint.h>'
t_assert_contains "$(cat "${PROBE_SOURCE}")" '#if !(UINT32_MAX > 0)'
_probe_file="$(printf '%s' "${args}" | sed -n 's/.*<-c><\([^>]*\)>.*/\1/p')"
t_assert_fails test -e "$(dirname "${_probe_file}")"
_reset
t_case "failed compile probes return one and clean their temporary tree"
t_assert_eq 1 "$(PROBE_STATUS=9 t_rc ffmpeg_try_cpp_condition '' 0)"
_probe_file="$(sed -n 's/.*<-c><\([^>]*\)>.*/\1/p' "${PROBE_CALLS}")"
t_assert_fails test -e "$(dirname "${_probe_file}")"
_reset
t_case "cross link flags keep sysroot, search dirs, linker, cflags and libraries in order"
t_assert_eq 0 "$(PROBE_CROSS=1 PROBE_LLD=1 USE_LLD=true t_rc ffmpeg_try_link_probe 'math.h' cos '-O1 -DTEST=2' '-lm -pthread')"
args="$(cat "${PROBE_CALLS}")"
t_assert_contains "${args}" '<--sysroot=/><-I/target/include><-L/target/lib><-fuse-ld=lld><-O1><-DTEST=2>'
t_assert_contains "${args}" '<-lm><-pthread>'
t_assert_contains "$(cat "${PROBE_SOURCE}")" 'long ffmpeg_probe_cos(void) { return (long)cos; }'
t_assert_contains "$(cat "${PROBE_SOURCE}")" 'ffmpeg_probe_cos() & 0xFFFF'
_reset
t_case "link probes preserve the lld opt-out and failed compiler verdict"
t_assert_eq 1 "$(PROBE_LLD=1 USE_LLD=off PROBE_STATUS=7 t_rc ffmpeg_try_link_probe '' missing)"
t_assert_fails rg -q -- '-fuse-ld=lld' "${PROBE_CALLS}"
_reset
t_case "compile debug captures diagnostics but the regular compile owns the verdict"
FFMPEG_PROBE_DEBUG=1 ffmpeg_try_cpp_condition '' 1
t_assert_eq 'probe diagnostic' "${_FFMPEG_LAST_PROBE_ERR}"
t_assert_eq 2 "$(wc -l < "${PROBE_CALLS}")"
_reset
t_case "debug mode does not add an extra link invocation"
t_assert_eq 0 "$(FFMPEG_PROBE_DEBUG=1 t_rc ffmpeg_try_link_probe '' '')"
t_assert_eq 1 "$(wc -l < "${PROBE_CALLS}")"
if builtin command -v cc >/dev/null 2>&1; then
  CC="$(builtin command -v cc)"
  t_case "native compilation rejects a false preprocessor condition"
  t_assert_eq 0 "$(t_rc ffmpeg_try_cpp_condition stdint.h 'UINT32_MAX > 0')"
  t_assert_eq 1 "$(t_rc ffmpeg_try_cpp_condition stdint.h 'UINT32_MAX == 0')"
  t_case "native linking rejects a missing symbol and accepts a real libc symbol"
  t_assert_eq 0 "$(t_rc ffmpeg_try_link_probe stdio.h printf)"
  t_assert_eq 1 "$(t_rc ffmpeg_try_link_probe stdio.h ant_missing_symbol)"
fi
# shellcheck source=../01-core/compiler-resolution.sh
source "${TESTS_DIR}/../01-core/compiler-resolution.sh"
resolve_host_compiler_for_lang() {
  printf 'host-%s' "$1"
  return "${HOST_RESOLVE_STATUS:-0}"
}
t_case "FFmpeg delegates host C selection and preserves resolver failures"
t_assert_eq host-c "$(resolve_ffmpeg_host_compiler)"
t_assert_eq 7 "$(HOST_RESOLVE_STATUS=7 t_rc resolve_ffmpeg_host_compiler)"
t_case "FFmpeg host wrappers retain isolated PATH, spaces and argument boundaries"
cat > "${D}/compiler with spaces" <<'HOST_COMPILER'
#!/bin/sh
printf 'PATH=%s\n' "$PATH"
printf '<%s>\n' "$@"
HOST_COMPILER
chmod +x "${D}/compiler with spaces"
wrapper="$(FFMPEG_HOST_TOOLCHAIN_DIR="${D}/host toolchain" prepare_ffmpeg_host_compiler_wrapper "${D}/compiler with spaces")"
t_assert_ok test -x "${wrapper}"
t_assert_eq $'PATH=/usr/bin:/bin\n<-B/usr/bin/>\n<one argument>\n<two>' "$("${wrapper}" 'one argument' two)"
t_summary
