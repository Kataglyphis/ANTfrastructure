#!/usr/bin/env bash
# python-app-data.py's file and lock rows against a scratch project; not covered: the bundle build around it or Windows' twin.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_PY="${TESTS_DIR}/../06-packaging/python-app-data.py"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# _project <lock body>: a project whose app.json ships one file and the models a lock names.
_project() {
  rm -rf "${work:?}/p" && mkdir -p "${work}/p/models" "${work}/p/out"
  printf 'notice\n' > "${work}/p/NOTICE.txt"
  printf '%s' "$1" > "${work}/p/models/models.lock"
  printf 'model\n' > "${work}/p/models/other_model.onnx"
  printf 'terms\n' > "${work}/p/models/other_model.LICENSE"
  printf '{"data": [{"from": "NOTICE.txt", "to": "NOTICE.txt"}, {"lock": "models/models.lock", "to": "share/app/models"}]}\n' \
    > "${work}/p/app.json"
}

_copy() { (cd "${work}/p" && python3 "${DATA_PY}" app.json out 2>&1); }

LOCK=$'# sha256 file url\naa  other_model.onnx  https://example.invalid/other_model.onnx\nbb  other_model.LICENSE  https://example.invalid/other_model.LICENSE\n'

t_case "a lock row ships the lock and every file it names, under the names the lock gives"
_project "${LOCK}"
out="$(_copy)"; rc=$?
t_assert_eq "0" "${rc}" "a complete lock copies: ${out}"
t_assert_eq "notice" "$(cat "${work}/p/out/NOTICE.txt")" "a plain row still copies"
t_assert_eq "model" "$(cat "${work}/p/out/share/app/models/other_model.onnx")" "the model the lock names"
t_assert_eq "terms" "$(cat "${work}/p/out/share/app/models/other_model.LICENSE")" "its licence"
t_assert_eq "$(cat "${work}/p/models/models.lock")" "$(cat "${work}/p/out/share/app/models/models.lock")" "the lock itself, byte-identical, so the app reads its model name"

t_case "a lock that names a file the checkout lacks fails"
_project "${LOCK}"
rm "${work}/p/models/other_model.LICENSE"
_copy >/dev/null; rc=$?
t_assert_eq "1" "${rc}" "a missing model file must not ship a partial bundle"

t_case "an empty lock and a lock naming a path are refused"
_project $'# sha256 file url\n'
out="$(_copy)"; rc=$?
t_assert_eq "1" "${rc}" "a lock with no rows ships no model"
t_assert_contains "${out}" "names no file" "the refusal says why"
_project $'aa  ../escape.onnx  https://example.invalid/x\n'
out="$(_copy)"; rc=$?
t_assert_eq "1" "${rc}" "a lock row may not reach outside its directory"
t_assert_contains "${out}" "names a path, not a file: ../escape.onnx" "the offending row is named"

t_summary
