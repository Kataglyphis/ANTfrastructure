#!/usr/bin/env bash
# Offline filename and traversal fixtures cover selectors and advisory find failures, not unreadable kernel mounts or real builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/stream-receipt-fixture.sh"
receipt=''
t_stream_workspace WORK receipt "${2:-}"
subject="${1:-$TESTS_DIR/../03-media/ort-provenance.sh}"

cat > "$WORK/startup.sh" <<'STARTUP'
set -u
source "${1%/*}/stream-receipt-fixture.sh"
if [ "$4" = failure ]; then mktemp() { return 23; }; fi
startup() {
  local directory=old optional=old
  t_stream_workspace directory optional "$3" || return "$?"
  [ -d "$directory" ] || return 27
  printf '%s' "$directory" > "$2"
  printf 'receipt:<%s>\n' "$optional"
}
startup "$@"
STARTUP

_ort_startup_run() {
  local status=0
  t_run_fixture_worker "$WORK/startup.sh" "$WORK/created" "$1" "$2" > "$WORK/startup.out" || status=$?
  t_assert_eq "$3" "$status"
  t_assert_eq "$4" "$(cat "$WORK/startup.out")"
}

t_case 'shared startup truncates an explicit receipt and cleans its local workspace'
printf sentinel > "$WORK/optional receipt"
_ort_startup_run "$WORK/optional receipt" healthy 0 "receipt:<$WORK/optional receipt>"
t_assert_eq '' "$(cat "$WORK/optional receipt")"
t_assert_fails test -d "$(cat "$WORK/created")"

t_case 'shared startup retains an omitted receipt and fails closed when workspace creation fails'
_ort_startup_run '' healthy 0 'receipt:<>'
t_assert_fails test -d "$(cat "$WORK/created")"
rm "$WORK/created"
_ort_startup_run '' failure 1 ''
t_assert_fails test -e "$WORK/created"

cat > "$WORK/worker.sh" <<'WORKER'
set -u
source "$1"
source "${1%/*}/shell-context-fixture.sh"
source "${1%/*}/stream-receipt-fixture.sh"
subject="$2" directory="$3" operation="$4" value="$5" failure="$6" strict="$7" context="$8"
source "$subject"
cd "$directory" || exit 1
declare -A _ORTG_SHA=()
_ORTG_COMPARED=0 _ORTG_FILES=0
_ORTG_FOUND_LINKS=()
if [ "$operation" != classify ]; then _ORTG_SHA[cpu_provider_factory.h]=' sentinel '; fi
find() {
  printf 'find' >> trace
  printf '<%s>' "$@" >> trace
  printf '\n' >> trace
  if [ "$failure" = count ] && [ "${!#}" = . ]; then printf '..'; return 23; fi
  command find "$@"
  if [ "$failure" = names ] && [ "${!#}" != . ]; then printf 'NAME-FAILURE\n' >&2; return 29; fi
}
_ortg_split_tokens() {
  _ORTG_INTREE=()
  _ORTG_OTHERS=(tree)
  _ORTG_OTHER_REALS=(tree)
}
_ort_classify() {
  if _ortg_is_bin "$value"; then printf 'BIN:0\n'; else printf 'BIN:1\n'; fi
  _ortg_name_finding "names/$value" ' (suffix)'
}
_ort_tree() { _ortg_scan_root tree ''; }
_ort_record() { _ortg_record_findings record; }
t_stream_run_worker "$context" "$strict" status "_ort_${operation}" returned
printf 'FILES:%s COMPARED:%s LINKS:%s\n' "$_ORTG_FILES" "$_ORTG_COMPARED" "${#_ORTG_FOUND_LINKS[@]}" > state
exit "$status"
WORKER

_ort_name_case() {
  local name="$1" binary="$2" finding="$3" status=0
  t_case "classification $name"
  printf 'BIN:%s\n' "$binary" > "$WORK/expected.out"
  case "$finding" in
    binary) printf 'names/%s is an ONNX Runtime binary the chain does not build (suffix)\n' "$name" >> "$WORK/expected.out" ;;
    archive) printf 'an ONNX Runtime archive: names/%s (suffix)\n' "$name" >> "$WORK/expected.out" ;;
  esac
  : > "$WORK/expected.err"; : > "$WORK/expected.trace"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$subject" "$WORK" classify "$name" none strict conditional
  t_assert_eq 0 "$status"
  t_stream_assert_files "$WORK" out err trace
  t_assert_eq 'FILES:0 COMPARED:0 LINKS:0' "$(cat "$WORK/state")"
  t_stream_record "$receipt" "$WORK" 'out err trace' classify "$name" "$status"
}

_ort_name_case libonnxruntime.so.1 0 binary
_ort_name_case ONNXRUNTIME.DLL 0 binary
_ort_name_case libonnxruntime_session.a 0 binary
_ort_name_case onnxruntime_pybind11_state.cp314.so 0 binary
_ort_name_case libonnxruntime-genai.so 1 none
_ort_name_case libonnxruntime_genai.so 1 none
_ort_name_case libonnxruntime.extensions.dll 1 none
_ort_name_case onnxruntimegenai.zip 1 none
_ort_name_case prefixONNXRUNTIME_GENAI.tar.gz 1 none
_ort_name_case onnxruntime.zip 1 archive
_ort_name_case onnxruntime.tar.xz 1 archive
_ort_name_case 'unrelated archive.tar.lzma2' 1 archive
_ort_name_case $'raw\tarchive\nfile.tar.lzma2' 1 archive
_ort_name_case libonnxruntime.so.bad 1 none
_ort_name_case unrelated.txt 1 none

mkdir -p "$WORK/tree/nested"
for name in libonnxruntime.so foreign.tar.lzma2 onnxruntime.zip cpu_provider_factory.h plain.txt libonnxruntime_genai.so nested/libonnxruntime.so; do
  : > "$WORK/tree/$name"
done
ln -s nested "$WORK/tree/dir-link"
ln -s absent "$WORK/tree/libonnxruntime_missing.so"
: > "$WORK/record"

_ort_scan_expected() {
  local operation="$1" failure="$2"
  if [ "$operation" = tree ]; then
    cat > "$WORK/expected.out" <<'TREE'
tree/libonnxruntime.so is an ONNX Runtime binary the chain does not build
an ONNX Runtime archive: tree/foreign.tar.lzma2
an ONNX Runtime archive: tree/onnxruntime.zip
tree/cpu_provider_factory.h is not the chain's cpu_provider_factory.h (foreign ONNX Runtime bytes)
tree/nested/libonnxruntime.so is an ONNX Runtime binary the chain does not build
tree/libonnxruntime_missing.so is an ONNX Runtime binary the chain does not build
TREE
    if [ "$failure" = names ]; then printf 'cannot read all of tree: NAME-FAILURE\n' >> "$WORK/expected.out"; fi
    expected_state='FILES:7 COMPARED:1 LINKS:1'
    if [ "$failure" = count ]; then expected_state='FILES:2 COMPARED:1 LINKS:1'; fi
  else
    cat > "$WORK/expected.out" <<'RECORD'
record searches tree: tree/libonnxruntime.so is an ONNX Runtime binary the chain does not build
record searches tree: an ONNX Runtime archive: tree/onnxruntime.zip
record searches tree: tree/cpu_provider_factory.h is not the chain's cpu_provider_factory.h (foreign ONNX Runtime bytes)
record searches tree: tree/libonnxruntime_missing.so is an ONNX Runtime binary the chain does not build
RECORD
    expected_state='FILES:0 COMPARED:0 LINKS:0'
  fi
  : > "$WORK/expected.err"
}

_ort_scan_case() {
  local operation="$1" failure="$2" strict="$3" context="$4" status=0 expected_state
  t_case "$*"
  _ort_scan_expected "$operation" "$failure"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$subject" "$WORK" "$operation" '' "$failure" "$strict" "$context"
  t_assert_eq 0 "$status"
  LC_ALL=C sort "$WORK/out" > "$WORK/sorted.out"
  LC_ALL=C sort "$WORK/expected.out" > "$WORK/sorted.expected"
  t_assert_ok cmp -s "$WORK/sorted.expected" "$WORK/sorted.out"
  t_assert_eq '' "$(t_stream_hex "$WORK/err")"
  t_assert_eq "$expected_state" "$(cat "$WORK/state")"
  t_stream_assert_return "$WORK" 0
  t_stream_record "$receipt" "$WORK" 'out err trace state' "$@" "$status"
}

for operation in tree record; do
  for failure in none count names; do
    for strict in strict relaxed; do
      for context in direct conditional; do _ort_scan_case "$operation" "$failure" "$strict" "$context"; done
    done
  done
done
t_summary
