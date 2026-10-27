#!/usr/bin/env bash
# Checks safe mutation registry updates; it does not run the recipes themselves.
set -u
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${tests_dir}/test-harness.sh"
root="$(cd "${tests_dir}/../../.." && pwd)"
script="${root}/docs/scripts/merge_mutation_recipes.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
assert_rejected_without_write() {
  t_assert_fails python3 "$script" --root "$work/project" --replace fixture.one --write "$1"
  t_assert_ok cmp "$work/before.json" "$work/project/docs/scripts/mutations.json"
}
mkdir -p "$work/project/docs/scripts"
printf 'original text\n' > "$work/project/target.txt"
printf '[]\n' > "$work/project/docs/scripts/mutations.json"
cat > "$work/new.json" <<'JSON'
[{"id":"fixture.one","target":"target.txt","find":"original text","replace":"broken","test":"false","why":"prove fixture"}]
JSON

t_case 'preview leaves the registry unchanged; an explicit write adds the recipe'
t_assert_ok python3 "$script" --root "$work/project" "$work/new.json"
t_assert_eq '[]' "$(cat "$work/project/docs/scripts/mutations.json")"
t_assert_ok python3 "$script" --root "$work/project" --write "$work/new.json"
t_assert_contains "$(cat "$work/project/docs/scripts/mutations.json")" 'fixture.one'
cp "$work/project/docs/scripts/mutations.json" "$work/before.json"

t_case 'a changed existing recipe needs an explicit ID and missing anchors never write'
sed 's/"replace":"broken"/"replace":"different"/' "$work/new.json" > "$work/changed.json"
t_assert_fails python3 "$script" --root "$work/project" --write "$work/changed.json"
t_assert_ok cmp "$work/before.json" "$work/project/docs/scripts/mutations.json"
t_assert_ok python3 "$script" --root "$work/project" --replace fixture.one --write "$work/changed.json"
t_assert_contains "$(cat "$work/project/docs/scripts/mutations.json")" 'different'
cp "$work/project/docs/scripts/mutations.json" "$work/before.json"
sed 's/original text/not present/' "$work/changed.json" > "$work/stale.json"
assert_rejected_without_write "$work/stale.json"

t_case 'duplicate inputs, unused replacement IDs and path traversal fail'
t_assert_fails python3 "$script" --root "$work/project" "$work/changed.json" "$work/changed.json"
t_assert_fails python3 "$script" --root "$work/project" --replace absent "$work/changed.json"
sed 's/target.txt/..\/outside.txt/' "$work/changed.json" > "$work/outside.json"
t_assert_fails python3 "$script" --root "$work/project" "$work/outside.json"
t_assert_ok cmp "$work/before.json" "$work/project/docs/scripts/mutations.json"

t_case 'a target symlink cannot escape the repository'
t_needs 'real symlinks' t_posix_symlinks
printf 'outside text\n' > "$work/outside.txt"
ln -s "$work/outside.txt" "$work/project/link.txt"
sed -e 's/target.txt/link.txt/' -e 's/original text/outside text/' "$work/new.json" > "$work/link.json"
assert_rejected_without_write "$work/link.json"

t_summary
