#!/usr/bin/env bash
# Tests for verify_dead_functions.py. The gate derives its root from its own path,
# so each case builds a throwaway tree with gate-tree.sh and plants a subject.sh,
# callers, and an allow file there. Fixture functions are
# written via printf so this file defines none of them itself.
# docs/code-quality-tooling.md#dead-shell-functions-dead-functions
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
GATE="${SCRIPTS_DIR}/verify_dead_functions.py"
PY="${PREFLIGHT_PYTHON:-python3}"
D='docs/'

DEAD=$'dead_fn() {\n  :\n}'
USED=$'used_fn() {\n  :\n}'
FROZEN_DEAD=$'linux/scripts/subject.sh\tdead_fn'
FROZEN_USED=$'linux/scripts/subject.sh\tused_fn'
MASKED=$'foo_fn() {\n  :\n}'
MASKING=$'foo_fn() {\n  :\n}\nfoo_fn "$@"'

# _fixture <subject.sh content> [allow content] -> tree path
_fixture() {
  gate_tree_subject dead-functions.allow "$1" "${2-}" \
    "${GATE}" "${SCRIPTS_DIR}/verify_code_size.py" "${SCRIPTS_DIR}/quality_allow.py"
}
_gate() { local d="$1"; shift; "${PY}" "${d}/linux/scripts/verify_dead_functions.py" "$@"; }
_run() { t_out _gate "$@"; }
_rc()  { t_rc _gate "$@"; }

# _expect rc|says|census|census-rc <want> <why> <subject> [allow] [caller-relpath caller-content]...
# One fixture per assertion: the exit code (rc) or a substring of the output (says).
_expect() {
  local mode="$1" want="$2" why="$3" subject="$4" allow="${5-}" fix
  shift 4; [ $# -gt 0 ] && shift
  fix="$(_fixture "${subject}" "${allow}")"
  while [ $# -ge 2 ]; do
    mkdir -p "$(dirname "${fix}/$1")"; printf '%s\n' "$2" > "${fix}/$1"; shift 2
  done
  case "${mode}" in
    rc)        t_assert_eq "${want}" "$(_rc "${fix}")" "${why}" ;;
    says)      t_assert_contains "$(_run "${fix}")" "${want}" "${why}" ;;
    census)    t_assert_contains "$(_run "${fix}" --census)" "${want}" "${why}" ;;
    census-rc) t_assert_eq "${want}" "$(_rc "${fix}" --census)" "${why}" ;;
  esac
  rm -rf "${fix}"
}
_verdict()   { _expect rc "$@"; }
_says()      { _expect says "$@"; }
_census()    { _expect census "$@"; }
_census_rc() { _expect census-rc "$@"; }
# _called <rc> <why> <caller.sh content>: used_fn defined, one line in caller.sh
_called()  { _verdict "$1" "$2" "${USED}" "" linux/scripts/caller.sh "$3"; }

t_case "a function nothing names fails, and says which"
_verdict 1 "printing is not enough; it must fail" "${DEAD}"
_says "NEW dead function" "the heading names the failure class" "${DEAD}"
_says "linux/scripts/subject.sh  dead_fn" "file and name, tab shown as two spaces" "${DEAD}"
_says "1 shell functions; 1 named nowhere else" "the census line is printed" "${DEAD}"

t_case "a function called from another shell file passes"
_called 0 "a plain call is a use" 'used_fn "$@"'
_says "OK: no new dead functions" "the pass line" "${USED}" "" \
  linux/host-config/tool.sh 'used_fn'

t_case "linux/host-config is scanned for definitions, not only for calls"
_verdict 1 "an operator tool's dead helper must fail too" ':' "" \
  linux/host-config/tool.sh "${DEAD}"
_says "linux/host-config/tool.sh  dead_fn" "the host-config path is reported" ':' "" \
  linux/host-config/tool.sh "${DEAD}"

t_case "a mention only inside a comment is still dead"
_called 1 "a whole-line comment is not a use" '# used_fn documents itself here'
_called 1 "a trailing comment is not a use" 'true # then used_fn would run'
_called 1 "a tab-indented comment is not a use" $'\t# used_fn would run here'
_called 1 "a comment above other code is not a use" $'# used_fn documents itself\ntrue'

t_case "a hash that is not a comment does not swallow the call after it"
_called 0 '${#arr[@]} is arithmetic, not a comment' 'n="${#arr[@]}"; used_fn "${n}"'
_called 0 '$# is the argument count, not a comment' '[ "$#" -gt 0 ] && used_fn'

t_case "a Dockerfile RUN naming the function is a use"
_verdict 0 "bash -c from a Dockerfile is how stages call helpers" "${USED}" "" \
  linux/Dockerfile.subject 'RUN bash -c ". /opt/subject.sh && used_fn"'
_verdict 1 "but a commented-out RUN is not" "${USED}" "" \
  linux/Dockerfile.subject '# RUN bash -c ". /opt/subject.sh && used_fn"'

t_case "workflows, docs/scripts tooling and the Makefile are corpus too"
_verdict 0 "a workflow step is a use" "${USED}" "" \
  .github/workflows/ci.yml $'jobs:\n  x:\n    steps:\n      - run: used_fn'
_verdict 0 "a python tool shelling out is a use" "${USED}" "" \
  docs/scripts/tool.py 'subprocess.run(["bash", "-c", "used_fn"])'
_verdict 0 "a Makefile recipe is a use" "${USED}" "" \
  Makefile $'x:\n\tused_fn'

t_case "prose, the Windows lane, built bundles and the gate's own baselines are not corpus"
_verdict 1 "docs/*.md never counts" "${USED}" "" \
  "${D}guide.md" 'Call used_fn to do the thing.'
_verdict 1 "windows/ is its own lane" "${USED}" "" \
  windows/scripts/x.ps1 'bash -c used_fn'
_verdict 1 "a built web bundle is an artifact, not a caller" "${USED}" "" \
  linux/webserver/dist/main.dart.js 'var a=used_fn(1);'
_verdict 0 "only the web bundle is excluded, not every dist/ path" "${USED}" "" \
  linux/scripts/dist/tool.sh 'used_fn'
_verdict 1 "a quality-gate .allow row describes code, it does not run it" "${USED}" "" \
  linux/scripts/function-size.allow 'linux/scripts/subject.sh | used_fn | 90 | baseline'
_verdict 1 "a .patch quotes code, it does not run it" "${USED}" "" \
  linux/scripts/fix.patch $'@@ -1 +1 @@\n+used_fn'
_verdict 1 "a .diff quotes code, it does not run it" "${USED}" "" \
  linux/scripts/fix.diff $'@@ -1 +1 @@\n+used_fn'
_verdict 1 "a patches/ directory holds upstream source, not callers" "${USED}" "" \
  linux/scripts/patches/fix.sh 'used_fn'
_verdict 1 "a pytest cache is a test-run artifact" "${USED}" "" \
  linux/scripts/.pytest_cache/v/cache/nodeids '["tests/x.py::used_fn"]'
_verdict 1 "a dart tool cache is generated too" "${USED}" "" \
  linux/webserver/.dart_tool/package_config.json '{"name": "used_fn"}'
_verdict 1 "a mutation manifest quotes code, it does not run it" "${USED}" "" \
  docs/scripts/mutations.json '[{"find": "used_fn", "replace": ":"}]'

t_case "word boundaries: a longer identifier is not a use"
_called 1 "a suffix is a different name" 'used_fn_extra'
_called 1 "a prefix is a different name" 'my_used_fn'
_called 0 "but a hyphen is a boundary" 'run-used_fn'

t_case "a second definition is not a use: two heads and zero calls is still dead"
_verdict 1 "definitions never count" "${DEAD}" "" \
  linux/scripts/other.sh "${DEAD}"
_says "linux/scripts/other.sh  dead_fn" "both copies are reported" "${DEAD}" "" \
  linux/scripts/other.sh "${DEAD}"
_verdict 1 "an indented one-liner head does not count as a use either" "${DEAD}" "" \
  linux/scripts/caller.sh '  dead_fn() { :; }'
_verdict 1 "nor does a head below the first line of the caller" "${DEAD}" "" \
  linux/scripts/caller.sh $'true\n  dead_fn() { :; }'
_verdict 1 "nor does the subject's own head below its first line" $'set -u\n'"${DEAD}"

t_case "a one-line function on the last line of a file is a definition"
_verdict 1 "the old brace walker never yielded a one-liner at EOF" 'dead_fn() { :; }'

t_case "the function keyword form is a definition too"
_verdict 1 "function name { is bash" $'function dead_fn {\n  :\n}'
_verdict 1 "function name() { is bash" $'function dead_fn() {\n  :\n}'

t_case "a frozen dead function passes -- the allow file itself is not a use"
_verdict 0 "frozen is the contract" "${DEAD}" "${FROZEN_DEAD}"
_verdict 0 "reason comments are allowed between rows" "${DEAD}" $'# reason\n'"${FROZEN_DEAD}"

t_case "a stale freeze fails, both when the function is called again and when it is gone"
_verdict 1 "a freeze must not outlive its subject" "${USED}" "${FROZEN_USED}" \
  linux/Dockerfile.x 'RUN used_fn'
_says "STALE entr" "the stale heading" "${USED}" "${FROZEN_USED}" \
  linux/scripts/caller.sh 'used_fn'
_says "linux/scripts/subject.sh  used_fn" "names the row to delete" "${USED}" "${FROZEN_USED}" \
  .github/ci.yml 'run: used_fn'
_verdict 1 "a frozen name that is no longer defined is stale" ':' "${FROZEN_DEAD}"

t_case "same-name masking: the gate cannot see a dead function another file also defines"
_verdict 0 "one corpus-wide name table is what makes the gate cheap, and blind here" \
  "${MASKED}" "" linux/scripts/other.sh "${MASKING}"
_census $'linux/scripts/subject.sh\tfoo_fn' "--census is the pass that does see it" \
  "${MASKED}" "" linux/scripts/other.sh "${MASKING}"
_census "1 definition(s) their own file never names again" "the considered count" \
  "${MASKED}" "" linux/scripts/other.sh "${MASKING}"
_census "1 of those in a file that sources nothing" "the isolated tier counts it too" \
  "${MASKED}" "" linux/scripts/other.sh "${MASKING}"
_census_rc 0 "the census reports, it never fails a build" "${MASKED}"

t_case "the masked census tier is keyed on (file, name), not on the file's reachability"
_census "masked (1)" "a second definer is what the one name table cannot separate" \
  $'. ./lib.sh\n'"${MASKED}" "" linux/scripts/other.sh "${MASKING}"
_census $'linux/scripts/subject.sh\tfoo_fn' "the masked row names file AND function" \
  $'. ./lib.sh\n'"${MASKED}" "" linux/scripts/other.sh "${MASKING}"
_census "none -- every candidate owns its name" "a name only one file defines is not masked" \
  "${DEAD}"
_census "1 share their name with another file's definition" "the masked count is in the header" \
  "${MASKED}" "" linux/scripts/other.sh "${MASKING}"

t_case "the census lists only files that source nothing and that nothing else names"
_census "0 of those in a file that sources nothing" "a file that sources a library can be called back into it" \
  $'. ./lib.sh\n'"${MASKED}" "" linux/scripts/other.sh "${MASKING}"
_census "none -- every candidate sits in a sourced or externally named file" \
  "the isolated tier says so in its own words" \
  "${MASKED}" "" linux/scripts/runner.sh 'bash subject.sh'
_census "0 of those in a file that sources nothing" "a file another file names by basename may be run from there" \
  "${MASKED}" "" linux/scripts/runner.sh 'bash subject.sh'

t_case "the 2026-09-04 DEAD group is deleted, rows and all"
ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)"
FFMPEG_SH="linux/scripts/03-media/build/ffmpeg/build-ffmpeg.sh"
# _defs <path> <name> -> how many `<name>() {` definitions live under <path>
_defs() { ( cd "${ROOT}" && grep -rhE "^[[:space:]]*$2\(\)[[:space:]]*\{" "$1" \
            --include='*.sh' 2>/dev/null | wc -l | tr -d ' ' ); }
for _fn in cpython_ext_dev_packages_optional cpython_ext_modules_optional \
           cpython_ext_modules_required _cpython_ext_modules_by_class \
           verify_shared_lib_optional; do
  t_assert_eq "0" "$(_defs linux "${_fn}")" "${_fn} was deleted as dead"
  t_assert_eq "0" "$(grep -c -e "${_fn}" "${SCRIPTS_DIR}/dead-functions.allow")" \
    "and its freeze went with it"
done
t_assert_eq "0" "$(_defs "${FFMPEG_SH}" cleanup)" \
  "same-name masking hides ffmpeg's cleanup() from the gate; only this pin sees it"

t_case "the REAL tree is clean today"
t_assert_eq "0" "$( "${PY}" "${GATE}" >/dev/null 2>&1; echo $? )"
t_assert_eq "0" "$( "${PY}" "${GATE}" --census >/dev/null 2>&1; echo $? )"

t_summary
