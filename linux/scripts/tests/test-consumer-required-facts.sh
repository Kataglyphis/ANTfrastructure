#!/usr/bin/env bash
# Extracted consumer verdicts cover evidence order, exact diagnostics and shell failure policy, not containers or installed SDKs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
source "${TESTS_DIR}/runtime-function-fixtures.sh"
SMOKE="${1:-${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh}"
RECEIPT="${2:-}"
[ -z "$RECEIPT" ] || : > "$RECEIPT"
for fn in _consumer_contract_fact _consumer_tooling_verdict _consumer_tool_verdict _consumer_jdk_verdict _consumer_android_verdict _consumer_required_facts_continue; do t_runtime_function "$SMOKE" "$fn"; done > "$WORK/functions.sh"
if grep -q '^_consumer_collect_required_facts() {' "$SMOKE" "${SMOKE%/*}/runtime-consumer-contract.sh"; then t_runtime_function "$SMOKE" _consumer_collect_required_facts >> "$WORK/functions.sh"; fi
sed '1s/_consumer_contract_fact/_fixture_contract_fact/' < <(t_runtime_function "$SMOKE" _consumer_contract_fact) >> "$WORK/functions.sh"
cat > "$WORK/worker.sh" <<'WORKER'
set -uo pipefail
source "$(dirname "$1")/shell-context-fixture.sh"
fixture="$2"; kind="$3"; probe="$4"; context="$5"; strict="$6"; fault="$7"; fault_key="$8"
source "$fixture/functions.sh"
_consumer_contract_fact() {
  builtin printf '%s %s\n' "$2" "$3" >> "$fixture/trace"
  _fixture_contract_fact "$@"
  if [ "$fault" = lookup ] && [ "$2:$3" = "$fault_key" ]; then return 17; fi
  return 0
}
printf() {
  if [ "$fault" = print ] && [[ "${1:-}" = NOFACT* ]]; then builtin printf "$@"; return 23; else builtin printf "$@"; fi
}
operation() { "_consumer_${kind}_verdict" 'fixture %s' "$probe" > "$fixture/output" 2> "$fixture/error"; }
[ "$strict" != strict ] || set -e
shell_fixture_run_context "$context" operation_status operation
builtin printf 'RETURNED status=%s\n' "$operation_status"
WORKER

_consumer_lookup_trace() {
  case "$1" in
    tool) printf 'ENV appimagetool\nFACT appimagetool-readable' ;;
    jdk) printf 'ENV java-home\nFACT java-on-path\nFACT javac' ;;
    off-missing) printf 'FACT android-payload-off' ;;
    off-yes) printf 'FACT android-payload-off\nENV android-home\nENV android-sdk-root' ;;
    android) printf 'FACT android-payload-off\nENV android-home\nENV android-sdk-root\nDIR android-platform-tools\nFACT android-path' ;;
  esac
}

_consumer_fact_case() {
  local kind="$1" name="$2" encoded="$3" expected="$4" trace_kind="$5" context="${6:-direct}" strict="${7:-strict}" fault="${8:-none}" fault_key="${9:-}"
  local probe trace output status expected_status=0 expected_return=0 expected_control='RETURNED status=0'
  probe="$(printf '%b' "$encoded")"; expected="${expected//@ROW@/fixture %s}"
  trace="$(_consumer_lookup_trace "$trace_kind")"
  if [ "$fault" = lookup ] && [ "$context/$strict" = direct/strict ]; then
    trace="$(awk -v stop="${fault_key/:/ }" '{print; if($0 == stop) exit}' <<< "$trace")"
    expected_status=17; expected_control=''; expected=''
  fi
  if [ "$fault" = print ]; then
    if [ "$context/$strict" = direct/strict ]; then expected_status=23; expected_control='';
    elif [ "$trace_kind" != off-missing ]; then expected_return=23; expected_control="RETURNED status=$expected_return"; fi
  fi
  : > "$WORK/trace"
  t_case "$kind $name $context $strict $fault"
  t_capture_command output status t_run_fixture_worker "$WORK/worker.sh" "$WORK" "$kind" "$probe" "$context" "$strict" "$fault" "$fault_key"
  t_assert_eq "$expected_status" "$status"
  t_assert_eq "$expected_control" "$output"
  t_assert_eq "$expected" "$(cat "$WORK/output")"
  t_assert_eq "$trace" "$(cat "$WORK/trace")"
  t_assert_eq '' "$(cat "$WORK/error")"
  t_record_fixture_receipt "$RECEIPT" "$kind/$name/$context/$strict/$fault" "$status" "$output" "$(cat "$WORK/output")" "$(cat "$WORK/trace")" "$(cat "$WORK/error")"
}
while IFS='|' read -r kind name probe expected trace; do _consumer_fact_case "$kind" "$name" "$probe" "$expected" "$trace"; done <<'CASES'
tool|missing|ENV appimagetool /tools/my %s tool|NOFACT @ROW@ no FACT appimagetool-readable line|tool
tool|empty|ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable |NOFACT @ROW@ no FACT appimagetool-readable line|tool
tool|path-before-permission|FACT appimagetool-readable no|BAD @ROW@ appimagetool is not on PATH at all|tool
tool|unreadable|ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable no|BAD @ROW@ /tools/my %s tool is not readable by the image user|tool
tool|healthy|ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable yes|OK @ROW@ /tools/my %s tool readable|tool
tool|unknown|ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable unknown|BAD @ROW@ /tools/my %s tool is not readable by the image user|tool
tool|first-duplicate|ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable yes\nFACT appimagetool-readable no|OK @ROW@ /tools/my %s tool readable|tool
tool|empty-first-duplicate|ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable \nFACT appimagetool-readable yes|NOFACT @ROW@ no FACT appimagetool-readable line|tool
tool|flag-space|ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable yes |BAD @ROW@ /tools/my %s tool is not readable by the image user|tool
jdk|missing-both|ENV java-home /jdk/my %s home|NOFACT @ROW@ no FACT java-on-path / FACT javac line|jdk
jdk|missing-onpath-priority|FACT javac no|NOFACT @ROW@ no FACT java-on-path / FACT javac line|jdk
jdk|missing-javac-priority|FACT java-on-path no|NOFACT @ROW@ no FACT java-on-path / FACT javac line|jdk
jdk|empty-onpath|FACT java-on-path \nFACT javac yes|NOFACT @ROW@ no FACT java-on-path / FACT javac line|jdk
jdk|empty-javac|FACT java-on-path yes\nFACT javac |NOFACT @ROW@ no FACT java-on-path / FACT javac line|jdk
jdk|path-before-home|FACT java-on-path no\nFACT javac no|BAD @ROW@ no java on PATH|jdk
jdk|home-before-compiler|FACT java-on-path yes\nFACT javac no|BAD @ROW@ java runs but JAVA_HOME is unset, which is what Gradle reads|jdk
jdk|jre|ENV java-home /jdk/my %s home\nFACT java-on-path yes\nFACT javac no|BAD @ROW@ JAVA_HOME=/jdk/my %s home has no bin/javac -- a JRE cannot compile|jdk
jdk|unknown-path|ENV java-home /jdk/my %s home\nFACT java-on-path unknown\nFACT javac yes|BAD @ROW@ no java on PATH|jdk
jdk|healthy|ENV java-home /jdk/my %s home\nFACT java-on-path yes\nFACT javac yes|OK @ROW@ java + JAVA_HOME=/jdk/my %s home with javac|jdk
jdk|first-duplicate|ENV java-home /jdk/my %s home\nFACT java-on-path no\nFACT java-on-path yes\nFACT javac yes|BAD @ROW@ no java on PATH|jdk
jdk|empty-first-duplicate|ENV java-home /jdk/my %s home\nFACT java-on-path \nFACT java-on-path yes\nFACT javac yes|NOFACT @ROW@ no FACT java-on-path / FACT javac line|jdk
android|missing-off|ENV android-home /sdk %s home\nDIR android-platform-tools yes\nFACT android-path yes|NOFACT @ROW@ no FACT android-payload-off line|off-missing
android|empty-off-first|FACT android-payload-off \nFACT android-payload-off yes\nENV android-home /sdk %s home|NOFACT @ROW@ no FACT android-payload-off line|off-missing
android|off-empty-env|FACT android-payload-off yes|SKIP @ROW@ the android payload is off for this image (/opt/android/.android-payload-off)|off-yes
android|off-home|FACT android-payload-off yes\nENV android-home /sdk %s home|BAD @ROW@ ANDROID_HOME=/sdk %s home / ANDROID_SDK_ROOT=<unset> while /opt/android/.android-payload-off says the image ships no SDK|off-yes
android|off-root|FACT android-payload-off yes\nENV android-sdk-root /sdk root|BAD @ROW@ ANDROID_HOME=<unset> / ANDROID_SDK_ROOT=/sdk root while /opt/android/.android-payload-off says the image ships no SDK|off-yes
android|off-both|FACT android-payload-off yes\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root|BAD @ROW@ ANDROID_HOME=/sdk %s home / ANDROID_SDK_ROOT=/sdk root while /opt/android/.android-payload-off says the image ships no SDK|off-yes
android|missing-dir|FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nFACT android-path yes|NOFACT @ROW@ no DIR android-platform-tools / FACT android-path line|android
android|missing-path|FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools yes|NOFACT @ROW@ no DIR android-platform-tools / FACT android-path line|android
android|empty-dir|FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools \nFACT android-path yes|NOFACT @ROW@ no DIR android-platform-tools / FACT android-path line|android
android|empty-path|FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools yes\nFACT android-path |NOFACT @ROW@ no DIR android-platform-tools / FACT android-path line|android
android|env-before-dir|FACT android-payload-off no\nENV android-sdk-root /sdk root\nDIR android-platform-tools no\nFACT android-path no|BAD @ROW@ ANDROID_HOME=<unset> / ANDROID_SDK_ROOT=/sdk root while the SDK ships in the image|android
android|bad-dir|FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools no\nFACT android-path no|BAD @ROW@ /sdk %s home/platform-tools does not exist|android
android|bad-path|FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools yes\nFACT android-path no|BAD @ROW@ neither /sdk %s home/platform-tools nor cmdline-tools/latest/bin is on PATH|android
android|unknown-off|FACT android-payload-off unknown\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools yes\nFACT android-path yes|OK @ROW@ /sdk %s home|android
android|healthy|FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools yes\nFACT android-path yes|OK @ROW@ /sdk %s home|android
android|first-off-duplicate|FACT android-payload-off yes\nFACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root|BAD @ROW@ ANDROID_HOME=/sdk %s home / ANDROID_SDK_ROOT=/sdk root while /opt/android/.android-payload-off says the image ships no SDK|off-yes
CASES

for context in direct conditional; do
  for strict in strict relaxed; do
    _consumer_fact_case tool failed-fact 'ENV appimagetool /tools/my %s tool\nFACT appimagetool-readable yes' 'OK @ROW@ /tools/my %s tool readable' tool "$context" "$strict" lookup FACT:appimagetool-readable
    _consumer_fact_case jdk failed-first-fact 'ENV java-home /jdk/my %s home\nFACT java-on-path yes\nFACT javac yes' 'OK @ROW@ java + JAVA_HOME=/jdk/my %s home with javac' jdk "$context" "$strict" lookup FACT:java-on-path
    _consumer_fact_case android failed-off-fact 'FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools yes\nFACT android-path yes' 'OK @ROW@ /sdk %s home' android "$context" "$strict" lookup FACT:android-payload-off
    _consumer_fact_case android failed-dir-fact 'FACT android-payload-off no\nENV android-home /sdk %s home\nENV android-sdk-root /sdk root\nDIR android-platform-tools yes\nFACT android-path yes' 'OK @ROW@ /sdk %s home' android "$context" "$strict" lookup DIR:android-platform-tools
    _consumer_fact_case tool failed-nofact-print '' 'NOFACT @ROW@ no FACT appimagetool-readable line' tool "$context" "$strict" print
    _consumer_fact_case jdk failed-nofact-print '' 'NOFACT @ROW@ no FACT java-on-path / FACT javac line' jdk "$context" "$strict" print
    _consumer_fact_case android failed-early-print '' 'NOFACT @ROW@ no FACT android-payload-off line' off-missing "$context" "$strict" print
    _consumer_fact_case android failed-late-print 'FACT android-payload-off no' 'NOFACT @ROW@ no DIR android-platform-tools / FACT android-path line' android "$context" "$strict" print
  done
done
t_summary
