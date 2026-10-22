#!/usr/bin/env bash
# The docs generator is pinned and isolated; a failed resolution or generation must fail the build.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="$(cd "${TESTS_DIR}/../lib" && pwd)"
PIN="$(sed -n 's/^DARTDOC_VERSION=//p' "${LIB}/../01-core/tool-pins.env")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/dart" <<'SH'
#!/usr/bin/env bash
printf 'cache=%s host=%s args=%s cwd=%s\n' "${PUB_CACHE:-}" "${PUB_HOSTED_URL:-}" "$*" "$PWD" >>"$EVENTS"
case "$*" in
  'pub global list') [ ! -f "$PUB_CACHE/active" ] || cat "$PUB_CACHE/active" ;;
  'pub global activate dartdoc '*)
    [ "${ACTIVATE_FAIL:-0}" = 0 ] || exit 23
    mkdir -p "$PUB_CACHE"
    if [ "${ACTIVATE_BAD:-0}" = 1 ]; then printf 'dartdoc 0.0.0\n' >"$PUB_CACHE/active"
    else printf 'dartdoc %s\n' "$5" >"$PUB_CACHE/active"; fi ;;
  'pub global run dartdoc:dartdoc') exit "${DOC_FAIL:-0}" ;;
  *) echo "unexpected dart command: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$WORK/bin/dart"

# _scenario <name> [ENV=value...]: the real generation function against a recording Dart executable.
_scenario() {
  local name="$1" dir
  shift
  dir="$WORK/$name"
  mkdir -p "$dir/project space"
  : >"$dir/events"
  # shellcheck disable=SC2016 # The child shell expands its own variables and command arrays.
  env -u DARTDOC_VERSION PATH="$WORK/bin:$PATH" EVENTS="$dir/events" \
    DARTDOC_BUILD_PROJECT_ROOT="$dir/project space" DARTDOC_BUILD_TOOL_CACHE="$dir/tools" \
    PUB_CACHE="$dir/app-cache" PUB_HOSTED_URL=https://caller.invalid \
    ACTIVATE_BAD=0 ACTIVATE_FAIL=0 CLEAN_FAIL=0 DOC_FAIL=0 OVERRIDE=0 "$@" bash -c '
      source "$1/dartdoc-build.sh"
      if [[ "${OVERRIDE:-0}" = 1 ]]; then
        _custom() { printf "custom=%s\n" "$*" >>"$EVENTS"; }
        DARTDOC_BUILD_DOC_CMD=(_custom "argument with spaces")
      fi
      if [[ "${CLEAN_FAIL:-0}" = 1 ]]; then
        _clean() { return 23; }
        DARTDOC_BUILD_CLEAN_CMD=(_clean)
      fi
      dartdoc_build_generate' _ "$LIB"
}

t_case "the exact tool pin comes from tool-pins.env"
t_assert_eq 1 "$(printf '%s\n' "$PIN" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$')"
t_assert_ok _scenario fresh
events="$(cat "$WORK/fresh/events")"
t_assert_contains "$events" "cache=$WORK/fresh/tools/$PIN host=https://pub.dev args=pub global activate dartdoc $PIN --no-executables"
t_assert_contains "$events" "cache=$WORK/fresh/tools/$PIN host=https://pub.dev args=pub global run dartdoc:dartdoc cwd=$WORK/fresh/project space"
t_assert_eq 0 "$(printf '%s\n' "$events" | grep -c 'args=doc')" "the bundled crashing generator is not used"
t_assert_eq 0 "$(printf '%s\n' "$events" | grep -c 'cache=.*/app-cache')" "the app/global tool cache is untouched"

t_case "an exact cached tool is reused, while another version is replaced"
t_assert_ok _scenario fresh
t_assert_eq 0 "$(grep -c 'args=pub global activate' "$WORK/fresh/events")"
printf 'dartdoc 0.0.0\n' >"$WORK/fresh/tools/$PIN/active"
t_assert_ok _scenario fresh
t_assert_contains "$(cat "$WORK/fresh/events")" "args=pub global activate dartdoc $PIN --no-executables"

t_case "an explicit caller command bypasses the resolver and preserves its arguments"
t_assert_ok _scenario custom OVERRIDE=1
t_assert_eq 'custom=argument with spaces' "$(cat "$WORK/custom/events")"
t_assert_ok test ! -d "$WORK/custom/tools"

t_case "resolution failure and a wrong activated version cannot run generation"
t_assert_rc 1 _scenario activate-failure ACTIVATE_FAIL=1
t_assert_no_grep "$WORK/activate-failure/events" 'args=pub global run'
t_assert_rc 1 _scenario corrupt ACTIVATE_BAD=1
t_assert_no_grep "$WORK/corrupt/events" 'args=pub global run'

t_case "clean and documentation failures propagate even without errexit"
t_assert_rc 1 _scenario clean-failure CLEAN_FAIL=1
t_assert_eq '' "$(cat "$WORK/clean-failure/events")"
t_assert_rc 24 _scenario doc-failure DOC_FAIL=24

t_summary
