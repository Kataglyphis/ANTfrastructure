#!/usr/bin/env bash
# Staged-path fixtures cover precedence and failure propagation, not target interpreter execution or ABI compatibility.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cross-toolchain-fixture.sh
source "${TESTS_DIR}/cross-toolchain-fixture.sh"
_work=''
cross_toolchain_fixture_init _work cross-python.sh "${1:-}" || exit 1
_root="$_work/stage/usr/local"
_version_failure=0
_root_failure=0
_triplet_failure=0
cross_target_python_major_minor() {
  printf 'version\n' >> "$_work/order"
  [[ "$_version_failure" == 0 ]] || return 7
  printf 3.99
}
cross_target_python_root() {
  printf 'root:%s\n' "$*" >> "$_work/order"
  [[ "$_root_failure" == 0 ]] || return 8
  printf '%s' "$_root"
}
cross_target_triplet() {
  printf 'triplet\n' >> "$_work/order"
  [[ "$_triplet_failure" == 0 ]] || return 9
  printf fixture-linux-gnu
}
mkdir -p "$_root/lib/pkgconfig" "$_root/include/fixture-linux-gnu/python3.99" "$_root/include/python3.99"
printf library > "$_root/lib/libpython3.99.so.1.0"

t_case 'staged paths precede host directories without needing runnable target Python'
t_assert_eq "$_root/lib" "$(cross_target_python_libdir arm64)"
t_assert_eq "$_root/lib/pkgconfig" "$(cross_target_python_pkgconfig_dir arm64)"
t_assert_eq "$_root/include/python3.99" "$(cross_target_python_include_dir arm64)"
t_assert_eq "$_root/include/fixture-linux-gnu/python3.99" "$(cross_target_python_arch_include_dir arm64)"
t_assert_eq "$_root/lib/libpython3.99.so.1.0" "$(cross_target_python_library arm64)"
printf library > "$_root/lib/libpython3.99.so"
t_assert_eq "$_root/lib/libpython3.99.so" "$(cross_target_python_library arm64)"
for suffix in '' -embed; do
  t_case "pc suffix [$suffix] composes a path without inventing an existence check"
  if [[ -z "$suffix" ]]; then fn=cross_target_python_pc; else fn=cross_target_python_embed_pc; fi
  t_assert_eq "$_root/lib/pkgconfig/python-3.99$suffix.pc" "$("$fn")"
done

t_case 'development readiness still requires both pc files and the staged library'
_rc=0
cross_target_python_dev_ready || _rc=$?
t_assert_eq 1 "$_rc"
for file in python-3.99.pc python-3.99-embed.pc; do printf pc > "$_root/lib/pkgconfig/$file"; done
t_assert_eq 0 "$(t_rc cross_target_python_dev_ready)"
rm "$_root/lib/pkgconfig/python-3.99-embed.pc"
t_assert_eq 1 "$(t_rc cross_target_python_dev_ready)"

_resolve_first_path() {
  printf '%s\n' "$@"
  return "$_resolver_failure"
}
_resolver_failure=0
for suffix in '' /pkgconfig; do
  t_case "directory candidate order and root argument forwarding [$suffix]"
  if [[ -z "$suffix" ]]; then fn=cross_target_python_libdir; else fn=cross_target_python_pkgconfig_dir; fi
  : > "$_work/order"
  actual=$("$fn" arm64 'second argument')
  expected=$(printf '%s\n' -d "$_root/lib$suffix" "/usr/local/lib$suffix" "/usr/lib/fixture-linux-gnu$suffix" "/usr/lib$suffix")
  t_assert_eq "$expected" "$actual"
  t_assert_eq $'root:arm64 second argument\ntriplet' "$(cat "$_work/order")"
  _root_failure=1 _triplet_failure=1
  expected=$(printf '%s\n' -d '' "/usr/local/lib$suffix" "/usr/lib/$suffix" "/usr/lib$suffix")
  t_assert_eq "$expected" "$("$fn" arm64)"
  _root_failure=0 _triplet_failure=0
done

t_case 'architecture headers keep every staged and system fallback in order'
expected=$(printf '%s\n' -d "$_root/include/fixture-linux-gnu/python3.99" "$_root/include/python3.99" \
  /usr/local/include/fixture-linux-gnu/python3.99 /usr/include/fixture-linux-gnu/python3.99 \
  /usr/local/include/python3.99 /usr/include/python3.99)
t_assert_eq "$expected" "$(cross_target_python_arch_include_dir arm64)"
t_case 'shared-library candidates retain unversioned and versioned order at each location'
expected=$(printf '%s\n' -f "$_root/lib/libpython3.99.so" "$_root/lib/libpython3.99.so.1.0" \
  /usr/local/lib/libpython3.99.so /usr/local/lib/libpython3.99.so.1.0 \
  /usr/lib/fixture-linux-gnu/libpython3.99.so /usr/lib/fixture-linux-gnu/libpython3.99.so.1.0 \
  /usr/lib/libpython3.99.so /usr/lib/libpython3.99.so.1.0)
t_assert_eq "$expected" "$(cross_target_python_library arm64)"

for fn in cross_target_python_arch_include_dir cross_target_python_library; do
  t_case "$fn retains context order, argument forwarding and local scope"
  python_mm=parent triplet=parent python_root=parent
  : > "$_work/order"
  "$fn" arm64 'second argument' > "$_work/candidates"
  t_assert_eq $'version\ntriplet\nroot:arm64 second argument' "$(cat "$_work/order")"
  t_assert_eq 'parent|parent|parent' "$python_mm|$triplet|$python_root"
  _version_failure=1
  : > "$_work/order"
  t_assert_eq 1 "$(t_rc "$fn" arm64)"
  t_assert_eq version "$(cat "$_work/order")" 'a missing version must stop before triplet and root lookup'
  _version_failure=0
done

_resolver_failure=6
for fn in cross_target_python_libdir cross_target_python_pkgconfig_dir cross_target_python_arch_include_dir cross_target_python_library; do
  t_case "$fn preserves resolver failure"
  t_assert_eq 6 "$(t_rc "$fn" arm64)"
done
for fn in cross_target_python_pc cross_target_python_embed_pc; do
  t_case "$fn maps an unresolved pc directory to failure"
  t_assert_eq 1 "$(t_rc "$fn")"
done

_version_failure=1
for fn in cross_target_python_pc cross_target_python_embed_pc; do
  t_case "$fn stops before directory lookup when version resolution fails"
  : > "$_work/order"
  t_assert_eq 1 "$(t_rc "$fn")"
  t_assert_eq version "$(cat "$_work/order")"
done

t_case 'the shared fixture cleans its scratch tree when its child exits'
child_dir=$(bash -c 'source "$1"
workspace=""
cross_toolchain_fixture_init workspace cross-python.sh || exit 1
printf "%s" "$workspace"
' _ "${TESTS_DIR}/cross-toolchain-fixture.sh")
t_assert_ok test -n "$child_dir"
t_assert_fails test -e "$child_dir"
t_case 'the shared fixture refuses an unknown module before creating a scratch tree'
t_assert_eq 2 "$(t_rc cross_toolchain_fixture_init _work unknown)"

t_summary
