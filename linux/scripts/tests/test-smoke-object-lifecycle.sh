#!/usr/bin/env bash
# Fake compilers cover object probes and cleanup; no SDK, target compiler or target binary runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../06-packaging/smoke-common.sh"
t_source_functions "${TESTS_DIR}/../06-packaging/smoke-android.sh" _check_ndk_object _check_ndk_compiler
if [ "$#" -gt 0 ]; then
  eval "$(t_fn_src "$1" _cc_check_object)"
  eval "$(t_fn_src "$2" _check_ndk_compiler)"
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scratch" "$work/bin"
export TMPDIR="$work/scratch" OBJECT_LOG="$work/input" ANDROID_API_LEVEL=34
cat > "$work/bin/aarch64-linux-android34-clang" <<'COMPILER'
#!/usr/bin/env bash
cat > "$OBJECT_LOG"
printf '%s\n' "$*" >> "$OBJECT_LOG"
[ "$OBJECT_COMPILE" = success ] || exit 7
printf 'object' > "$6"
COMPILER
chmod +x "$work/bin/aarch64-linux-android34-clang"
smoke_elf_machine_of() { printf '%s' "$OBJECT_MACHINE"; }
smoke_elf_machine_grep() { printf '%s' "$OBJECT_EXPECTED"; }
smoke_host_arch() { printf '%s' "$1"; }

for probe in native ndk; do
  for scenario in match wrong unreadable compile-failure; do
    t_case "$probe object probe: $scenario"
    FAILURES=0
    export OBJECT_COMPILE=success
    OBJECT_MACHINE=AArch64 OBJECT_EXPECTED=AArch64
    case "$scenario" in
      wrong) OBJECT_MACHINE=X86-64 ;;
      unreadable) OBJECT_MACHINE='' ;;
      compile-failure) OBJECT_COMPILE=failed ;;
    esac
    output="$work/output"
    if [ "$probe" = native ]; then
      _cc_check_object "$work/bin/aarch64-linux-android34-clang" fixture AArch64 > "$output" 2>&1
      program='int answer(void){return 42;}'
    else
      _check_ndk_compiler "$work" aarch64 > "$output" 2>&1
      program='int f(void){return 1;}'
    fi
    expected=1
    [ "$scenario" != match ] || expected=0
    t_assert_eq "$expected" "$FAILURES" 'object verdict accounts for exactly one failed probe'
    t_assert_contains "$(cat "$OBJECT_LOG")" "$program" 'caller retains its original probe program'
    t_assert_eq 0 "$(ls -A "$TMPDIR" | wc -l | tr -d ' ')" 'object directory is cleaned'
  done
done

t_case 'NDK does not accept an empty architecture mapping'
FAILURES=0 OBJECT_MACHINE=AArch64 OBJECT_EXPECTED=''
export OBJECT_COMPILE=success
_check_ndk_compiler "$work" aarch64 > "$work/output" 2>&1
t_assert_eq 1 "$FAILURES"
t_assert_contains "$(cat "$work/output")" 'no ELF-machine mapping'

t_case 'a failing verifier returns its status and still removes its object'
object_verifier() { test -f "$1" || return 99; return 23; }
status=0
smoke_with_compiled_object "$work/bin/aarch64-linux-android34-clang" fixture result.o object_verifier || status=$?
t_assert_eq 23 "$status"
t_assert_eq 0 "$(ls -A "$TMPDIR" | wc -l | tr -d ' ')"

t_case 'cleanup failure cannot make a successful probe green'
object_verifier() { if test -f "$1"; then return 0; fi; return 1; }
rm() { return 73; }
status=0
smoke_with_compiled_object "$work/bin/aarch64-linux-android34-clang" fixture result.o object_verifier || status=$?
t_assert_eq 73 "$status"
FAILURES=0
_cc_check_object "$work/bin/aarch64-linux-android34-clang" fixture AArch64 > "$work/output" 2>&1
t_assert_eq 1 "$FAILURES" 'caller records a failed object lifecycle'
unset -f rm
command rm -rf "${TMPDIR:?}"/*

t_case 'failed temporary-directory allocation never invokes the compiler'
mktemp() {
  case "$temporary_mode" in
    failed) return 71 ;;
    missing) printf '%s' "$work/absent" ;;
  esac
}
for temporary_mode in failed empty missing; do
  rm -f "$OBJECT_LOG"
  status=0
  smoke_with_compiled_object "$work/bin/aarch64-linux-android34-clang" fixture result.o object_verifier || status=$?
  t_assert_eq 1 "$status" "$temporary_mode allocation cannot pass"
  t_assert_fails test -e "$OBJECT_LOG"
done
unset -f mktemp
t_summary
