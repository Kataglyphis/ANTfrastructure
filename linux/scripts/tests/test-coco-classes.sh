#!/usr/bin/env bash
# The canonical COCO class list and its shared-assets row; not covered: a consumer's copy, which its own shared-config check grades.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(cd "${TESTS_DIR}/../../../shared/config" && pwd)"
LIST="${CONFIG}/coco-classes.txt"
MANIFEST="${CONFIG}/shared-assets.manifest"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"

t_case "the list names 80 distinct classes, one per line, at their class ids"
t_assert_eq "80" "$(grep -c '' "${LIST}")" "every class id 0-79 must have exactly one line"
t_assert_eq "80" "$(LC_ALL=C sort -u "${LIST}" | grep -c .)" "a repeated or blank name would shift every later id"
t_assert_eq "" "$(grep -n -e $'^[ \t]' -e $'[ \t\r]$' "${LIST}" || true)" "loaders compare names byte for byte"
t_assert_eq "person" "$(sed -n 1p "${LIST}")" "class 0"
t_assert_eq "cat" "$(sed -n 16p "${LIST}")" "class 15, the golden tests' class"
t_assert_eq "toothbrush" "$(sed -n 80p "${LIST}")" "class 79"
t_assert_eq "" "$(tail -c 1 "${LIST}" | tr -d '\n')" "the file ends with a newline"

t_case "the shared-assets registry offers the list as an exact copy"
row="$(grep -E '^coco-classes[[:space:]]*\|' "${MANIFEST}" || true)"
t_assert_contains "${row}" "shared/config/coco-classes.txt" "consumers sync the canonical file"
t_assert_contains "${row}" "| exact |" "a copy must match byte for byte"

t_summary
