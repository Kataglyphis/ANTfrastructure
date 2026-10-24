#!/usr/bin/env bash
# Disposable source trees cover required module exports and import failures, not GCC compilation or Rust/documentation tools.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
scripts="${1:-${TESTS_DIR}/..}"

_numeric_import_tree() {
  local root="$1"
  mkdir -p "$root/toolchain/rust" "$root/01-core" "$root/lib"
  cp "$scripts/02-toolchain/gcc.sh" "$root/toolchain/"
  cp "$scripts/02-toolchain/bootstrap-import.sh" "$root/toolchain/"
  sed "s|/opt/scripts/core|$root/mounted|g" "$scripts/02-toolchain/bootstrap.sh" > "$root/toolchain/bootstrap.sh"
  cp "$scripts/01-core/load-versions-env.sh" "$scripts/01-core/logging.sh" "$scripts/01-core/elf-strip.sh" "$scripts/01-core/compiler-cache-utils.sh" "$root/01-core/"
  cp "$scripts/02-toolchain/rust/version_util.sh" "$root/toolchain/rust/"
  printf 'path_symlink_missing() { :; }\n' > "$root/01-core/path-helpers.sh"
  printf 'install_err_trap() { :; }\n' > "$root/01-core/common.sh"
  : > "$root/01-core/tool-pins.env"
  awk '{print} /^install_err_trap$/ {p=1; exit} END {if (!p) exit 1}' "$scripts/02-toolchain/build-gcc.sh" > "$root/toolchain/build-prefix.sh" || return 1
  t_fn_src "$scripts/lib/dartdoc-build.sh" _dartdoc_build_default_doc > "$root/lib/dartdoc.sh"
}

_numeric_break_import() {
  local root="$1" failure="$2"
  case "$failure" in
    healthy|guard) ;;
    old) printf 'load_versions_env() { :; }\n' > "$root/01-core/load-versions-env.sh" ;;
    missing) rm "$root/01-core/load-versions-env.sh" ;;
    source-return) printf 'load_versions_env() { :; }\nversion_has_numeric_parts() { return 0; }\nreturn 23\n' > "$root/01-core/load-versions-env.sh" ;;
    source-parse) printf 'load_versions_env() { :; }\nversion_has_numeric_parts() { return 0; }\nif ; then\n' > "$root/01-core/load-versions-env.sh" ;;
    bootstrap-missing) rm "$root/toolchain/bootstrap.sh" ;;
    initializer-missing) rm "$root/toolchain/bootstrap-import.sh" ;;
    bootstrap-return) printf 'return 31\n' > "$root/toolchain/bootstrap.sh" ;;
    bootstrap-old) printf 'source_toolchain_common_or_fallback() { :; }\nsource_toolchain_elf_strip() { :; }\n' > "$root/toolchain/bootstrap.sh" ;;
  esac
}

cat > "$WORK/worker.sh" <<'WORKER'
set -u
harness="$1" root="$2" consumer="$3" failure="$4" context="$5"
source "${harness%/*}/shell-context-fixture.sh"
err() { printf 'ERR:%s\n' "$*" >&2; exit 1; }
info() { :; }
dart() {
  if [ "$*" = 'pub global list' ]; then printf 'dartdoc 1.2.3\n'
  else printf 'DOC\n' >> "$root/actions"; fi
}
case "$failure" in
  bootstrap-missing|bootstrap-return)
    source_toolchain_required() { :; }
    source_toolchain_common_or_fallback() { :; }
    source_toolchain_elf_strip() { :; }
    install_err_trap() { :; } ;;
esac
if [ "$failure" = guard ]; then
  _LOAD_VERSIONS_ENV_SH_LOADED=1
  load_versions_env() { :; }
fi
unset NO_COLOR
NO_COLOR=1
_import_consumer() {
  case "$consumer" in
    gcc) cd "$root/toolchain"; source gcc.sh ;;
    build-gcc) source "$root/toolchain/build-prefix.sh" ;;
    rust) source "$root/toolchain/rust/version_util.sh" --normalize 1.2.3 ;;
    dartdoc)
      _DARTDOC_BUILD_LIB_DIR="$root/lib"; DARTDOC_BUILD_TOOL_CACHE="$root/cache"; DARTDOC_VERSION=1.2.3
      source "$root/lib/dartdoc.sh"
      _dartdoc_build_default_doc ;;
  esac
}
set -e
shell_fixture_run_context "$context" status _import_consumer
if [ "$status" -eq 0 ]; then printf 'READY\n'; fi
exit "$status"
WORKER

_numeric_import_case() {
  local consumer="$1" failure="$2" context="$3" root="$WORK/$1-$2-$3" status=0 expected=1
  _numeric_import_tree "$root" || exit 1
  _numeric_break_import "$root" "$failure"
  : > "$root/actions"
  case "$failure" in healthy) expected=0 ;; source-return) expected=23 ;; source-parse) expected=2 ;; bootstrap-return) expected=31 ;; esac
  t_case "$consumer $failure $context"
  t_run_fixture_worker "$WORK/worker.sh" "$root" "$consumer" "$failure" "$context" > "$root/out" 2> "$root/err" || status=$?
  t_assert_eq "$expected" "$status"
  if [ "$failure" = healthy ]; then
    t_assert_contains "$(cat "$root/out")" READY
  else
    t_assert_eq 1 "$(t_rc grep -q READY "$root/out")"
    t_assert_fails test -s "$root/actions"
    case "$failure" in source-return|bootstrap-return) ;; *) t_assert_ok test -s "$root/err" ;; esac
    case "$failure:$consumer" in
      old:gcc|guard:gcc|old:build-gcc|guard:build-gcc)
        t_assert_contains "$(cat "$root/err")" 'ERROR: toolchain bootstrap requires version_has_numeric_parts from load-versions-env.sh' ;;
      old:rust|guard:rust|old:dartdoc|guard:dartdoc)
        t_assert_contains "$(cat "$root/err")" 'Required version_has_numeric_parts missing from load-versions-env.sh.' ;;
      bootstrap-old:*)
        printf 'ERROR: bootstrap.sh does not provide source_toolchain_required\n' > "$root/expected.err"
        t_assert_ok cmp -s "$root/expected.err" "$root/err" ;;
    esac
  fi
}

for consumer in gcc build-gcc rust dartdoc; do
  for failure in healthy missing old guard source-return source-parse; do
    for context in direct conditional; do _numeric_import_case "$consumer" "$failure" "$context"; done
  done
done
for failure in bootstrap-missing bootstrap-return bootstrap-old initializer-missing; do
  for consumer in gcc build-gcc; do
    for context in direct conditional; do _numeric_import_case "$consumer" "$failure" "$context"; done
  done
done

t_case 'GCC source by bare filename also works with adjacent compiler companions'
root="$WORK/flat"; _numeric_import_tree "$root" || exit 1
mv "$root/01-core/load-versions-env.sh" "$root/toolchain/load-versions-env.sh"
status=0
(cd "$root/toolchain"; bash -e -c 'source gcc.sh; gcc_resolve_full_version 1.2.3 fallback') > "$root/out" 2> "$root/err" || status=$?
t_assert_eq 0 "$status"
t_assert_eq 1.2.3 "$(cat "$root/out")"

t_case 'legacy required-file callers retain conditional nonzero-source normalization'
root="$WORK/legacy"; _numeric_import_tree "$root" || exit 1
printf 'required_export() { :; }\nreturn 23\n' > "$root/toolchain/fixture.sh"
output="$(bash -e -c 'source "$1"; if source_toolchain_required "$2" fixture.sh; then printf accepted; fi' _ "$root/toolchain/bootstrap.sh" "$root/toolchain")"
t_assert_eq accepted "$output"
t_case 'required-export return disposition keeps the raw source status without exiting its conditional caller'
status=0
output="$(bash -e -c 'source "$1"; if source_toolchain_required "$2" fixture.sh return core-first required_export; then exit 29; else status=$?; fi; printf "caught:%s" "$status"; exit "$status"' _ "$root/toolchain/bootstrap.sh" "$root/toolchain" 2> "$root/err")" || status=$?
t_assert_eq 23 "$status"
t_assert_eq caught:23 "$output"
t_summary
