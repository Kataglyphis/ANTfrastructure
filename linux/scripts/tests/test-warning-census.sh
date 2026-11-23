#!/usr/bin/env bash
# verify_warning_census.py over fixture build logs: what counts as an own warning, and the census verdicts.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
_PY="${PREFLIGHT_PYTHON:-python3}"
GATE="${TESTS_DIR}/../verify_warning_census.py"
w="$(t_mktemp -d)"

# A GitHub-timestamped GCC log: own warnings twice through one header, a foreign one, and two compile lines.
cat > "${w}/gcc.log" <<'LOG'
2026-11-23T12:00:00.0000000Z [1/2] Building CXX object Src/CMakeFiles/app.dir/app.cpp.o
2026-11-23T12:00:01.0000000Z /workspace/Src/app.hpp:10:5: warning: declaration of 'x' shadows a member [-Wshadow]
2026-11-23T12:00:02.0000000Z [2/2] Building CXX object Src/CMakeFiles/app.dir/main.cpp.o
2026-11-23T12:00:03.0000000Z /workspace/Src/app.hpp:10:5: warning: declaration of 'x' shadows a member [-Wshadow]
2026-11-23T12:00:04.0000000Z /workspace/Src/main.cpp:3:1: warning: "GLM_FORCE_RADIANS" redefined
2026-11-23T12:00:05.0000000Z /workspace/third_party/SPDLOG/include/spdlog/fmt/bundled/format.h:1209:11: warning: writing 2 bytes [-Wstringop-overflow=]
2026-11-23T12:00:06.0000000Z /usr/include/c++/16/bits/stl_vector.h:5:1: warning: in a system header [-Wconversion]
2026-11-23T12:00:07.0000000Z /workspace/Src/main.cpp:9:1: warning: use a trailing return type [modernize-use-trailing-return-type]
LOG
# census <lane> <census file> [--write]: the gate's exit status and what it said.
census() { "${_PY}" "${GATE}" --lane "$1" --census "$2" "${@:3}" "${w}/gcc.log" 2>&1; }

t_case "a header's warning counts once; foreign code, system headers and clang-tidy findings not at all"
t_assert_contains "$(census gcc "${w}/new.census" --write)" "2 own warning(s) over 2 flag(s), 2 compile line(s)"
t_assert_eq "gcc | -W(unnamed) | 1
gcc | -Wshadow | 1" "$(cat "${w}/new.census")" "the rows are the counts per flag, sorted"

t_case "the census as written holds: same counts, green"
census gcc "${w}/new.census" >/dev/null
t_assert_eq 0 "$?" "an unchanged count must pass"

t_case "a grown flag is red"
printf 'gcc | -W(unnamed) | 1\n' > "${w}/grew.census"
t_assert_contains "$(census gcc "${w}/grew.census")" "-Wshadow GREW from 0 to 1"
census gcc "${w}/grew.census" >/dev/null
t_assert_eq 1 "$?" "a new warning must fail the lane"

t_case "a fixed warning is red until its row is lowered in the same commit"
printf 'gcc | -W(unnamed) | 1\ngcc | -Wshadow | 3\n' > "${w}/drop.census"
t_assert_contains "$(census gcc "${w}/drop.census")" "lower the row to 1 in this commit"

t_case "another lane's rows are kept and not graded here"
printf 'clang | -Wshadow | 9\n' > "${w}/lanes.census"
census gcc "${w}/lanes.census" --write >/dev/null
t_assert_contains "$(cat "${w}/lanes.census")" "clang | -Wshadow | 9"
census gcc "${w}/lanes.census" >/dev/null
t_assert_eq 0 "$?" "the clang rows must not fail the gcc lane"

t_case "a log that compiled nothing grades nothing, and says so"
printf 'ninja: no work to do.\n' > "${w}/empty.log"
out="$("${_PY}" "${GATE}" --lane gcc --census "${w}/new.census" "${w}/empty.log" 2>&1)"
t_assert_eq 1 "$?" "an empty build must not pass as zero warnings"
t_assert_contains "${out}" "compiled nothing"

t_case "a malformed census row is refused"
printf 'gcc | -Wshadow\n' > "${w}/bad.census"
t_assert_contains "$(census gcc "${w}/bad.census")" "expected '<lane> | <flag> | <count>'"

t_summary
