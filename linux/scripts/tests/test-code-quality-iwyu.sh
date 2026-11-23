#!/usr/bin/env bash
# Fixture sources and a stub iwyu_tool cover which units IWYU reads and the report's verdict, not IWYU itself.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../lib/code-quality.sh
source "${TESTS_DIR}/../lib/code-quality.sh"

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
mkdir -p "${w}/src" "${w}/bin"
printf '#include <string>\nint plain();\n' > "${w}/src/plain.cpp"
printf '// import is a word here, not a declaration\n#include <vector>\n' > "${w}/src/comment.cpp"
printf 'module;\n#include <string>\nmodule kataglyphis.loader;\n' > "${w}/src/unit.cpp"
printf '#include <string>\nimport kataglyphis.loader;\n' > "${w}/src/importer.cpp"
printf '  export module kataglyphis.api;\n' > "${w}/src/indented.cpp"
printf 'import <vector>;\n' > "${w}/src/header_unit.cpp"
printf '#include "x.h"\n' > "${w}/src/x.h"

t_case "IWYU reads the units without a module declaration or import, and no header"
t_assert_eq "./src/comment.cpp ./src/plain.cpp " "$(cd "${w}" && code_quality_find_iwyu_files . | LC_ALL=C sort | tr '\n' ' ')"

# stub <exit status> <output lines>...: an iwyu_tool that prints the lines and exits with the status.
stub() {
  local status="$1"
  shift
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\nexit %s\n' "$(printf '%q ' "$@")" "${status}" > "${w}/bin/iwyu_tool"
  chmod +x "${w}/bin/iwyu_tool"
}
run() ( PATH="${w}/bin:${PATH}" code_quality_run_iwyu "${w}/db" "${w}/logs/iwyu.txt" "$@" 2>&1 )
run_strict() ( set -euo pipefail; PATH="${w}/bin:${PATH}" code_quality_run_iwyu "${w}/db" "${w}/logs/iwyu.txt" "$@" 2>&1 )

t_case "suggestions are a report: green, with the count of files that would change"
stub 2 'src/a.cpp should remove these lines:' 'The full include-list for src/a.cpp:' 'The full include-list for src/a.cpp:' \
  '(src/b.cpp has correct #includes/fwd-decls)'
out="$(run src/a.cpp src/b.cpp)"
t_assert_eq 0 "$?" "suggestions must not fail the report"
t_assert_contains "${out}" "IWYU: 1 file(s) with include suggestions from 2 of 2 unit(s) read"
t_assert_contains "$(cat "${w}/logs/iwyu.txt")" "has correct #includes"

t_case "a strict caller gets the same verdict: suggestions and a clean log do not abort it"
out="$(run_strict src/a.cpp src/b.cpp)"
t_assert_eq 0 "$?" "errexit must not turn suggestions into a failure"
t_assert_contains "${out}" "from 2 of 2 unit(s) read"
stub 0 '(src/a.cpp has correct #includes/fwd-decls)'
t_assert_contains "$(run_strict ./src/a.cpp)" "0 file(s) with include suggestions from 1 of 1"

t_case "a unit IWYU could not read is red, as it graded nothing there"
stub 0 'src/a.cpp:12:1: error: PCH file uses a newer PCH format that cannot be read' \
  '(src/a.cpp has correct #includes/fwd-decls)'
run src/a.cpp >/dev/null
t_assert_eq 1 "$?" "an unread unit must fail the gate"

t_case "a missing header is a fatal error, and that unit is red too"
stub 0 "src/a.cpp:3:10: fatal error: 'missing.h' file not found" '(src/a.cpp has correct #includes/fwd-decls)'
run src/a.cpp >/dev/null
t_assert_eq 1 "$?" "a fatal error must fail the gate, as IWYU read that unit no further"

t_case "a driver that did not run, or stopped early, is red"
stub 127
t_assert_contains "$(run src/a.cpp)" "reported on 0 of 1 unit(s) (iwyu_tool exited 127)"
stub 7 'Unable to find a compilation database'
run src/a.cpp >/dev/null
t_assert_eq 1 "$?" "a driver failure must fail the gate"

t_case "a unit missing from the compile DB is red; units match by path suffix"
stub 0 '(/workspace/src/a.cpp has correct #includes/fwd-decls)'
out="$(run ./src/a.cpp src/b.cpp)"
t_assert_eq 1 "$?" "one of two units read must fail the gate"
t_assert_contains "${out}" "reported on 1 of 2 unit(s)"
t_assert_contains "$(run ./src/a.cpp)" "from 1 of 1 unit(s) read"

t_case "no unit to read is green and runs no IWYU"
stub 0 'src/a.cpp:1:1: error: must not run'
t_assert_contains "$(run)" "no unit without modules to read"

t_summary
