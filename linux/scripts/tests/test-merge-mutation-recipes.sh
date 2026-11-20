#!/usr/bin/env bash
# Checks safe, lossless ASCII registry updates; it does not run the recipes themselves.
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

t_case 'escaped negative-test strings remain ASCII and round-trip without changing recipes'
cat > "$work/unicode.json" <<'JSON'
[{"id":"fixture.unicode","target":"target.txt","find":"original text","replace":"\u00c2\u00b0 / \u00b0 / \ud83d\udc1c","test":"false","why":"Preserve \u00fc and intentional corrupt text as data."}]
JSON
t_assert_ok python3 "$script" --root "$work/project" --write "$work/unicode.json"
t_assert_ok python3 - "$work/project/docs/scripts/mutations.json" "$work/before.json" "$work/unicode.json" <<'PY'
import json
import sys
from pathlib import Path

registry, before, incoming = (Path(name) for name in sys.argv[1:])
text = registry.read_text(encoding="utf-8")
assert text.isascii(), "Negative-test strings must stay escaped in the registry source"
assert "\\u00c2\\u00b0" in text and "\\ud83d\\udc1c" in text
assert json.loads(text) == json.loads(before.read_text()) + json.loads(incoming.read_text())
PY
cp "$work/project/docs/scripts/mutations.json" "$work/unicode-before.json"
t_assert_ok python3 "$script" --root "$work/project" --write "$work/unicode.json"
t_assert_ok cmp "$work/unicode-before.json" "$work/project/docs/scripts/mutations.json"

t_summary
