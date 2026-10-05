#!/usr/bin/env bash
# t_skip_unless and run-tests.sh's exit-77 handling: only a Git Bash host may skip a suite (CON61).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# uname stubs that answer -s as a Linux or a Git Bash host; everything else goes to the real one.
for host in linux:Linux gitbash:MINGW64_NT-10.0-26300; do
  mkdir -p "${_WORK}/${host%%:*}"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = -s ] && { printf "%%s\\n" "%s"; exit 0; }\nexec /usr/bin/uname "$@"\n' \
    "${host#*:}" > "${_WORK}/${host%%:*}/uname"
  chmod +x "${_WORK}/${host%%:*}/uname"
done

# _suite <name> <body>: a suite file in the fake tests dir that sources the real harness.
mkdir -p "${_WORK}/tests"
cp "${TESTS_DIR}/test-harness.sh" "${TESTS_DIR}/run-tests.sh" "${_WORK}/tests/"
_suite() {
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/test-harness.sh"\nt_case one\n%s\nt_assert_ok true\nt_summary\n' "$2" \
    > "${_WORK}/tests/$1"
}
_run() {  # <host> <file>: rc|output of one suite under that host's uname
  local out rc
  out="$(PATH="${_WORK}/$1:${PATH}" bash "${_WORK}/tests/$2" 2>&1)"; rc=$?
  printf '%s|%s' "${rc}" "${out}"
}

_suite test-has.sh 't_skip_unless "a shell" command -v bash'
_suite test-lacks.sh 't_skip_unless "the frobnicator" command -v no-such-frobnicator'

t_case "a prerequisite that is there lets the suite run, on any host"
t_assert_contains "$(_run linux test-has.sh)" "1 assertion(s) passed"
t_assert_contains "$(_run gitbash test-has.sh)" "1 assertion(s) passed"

t_case "on Linux a missing prerequisite FAILS the suite: CI must never shrink silently"
out="$(_run linux test-lacks.sh)"
t_assert_eq "1" "${out%%|*}"
t_assert_contains "${out}" "prerequisite missing: the frobnicator"

t_case "on Git Bash it skips with exit 77 and says what is missing"
out="$(_run gitbash test-lacks.sh)"
t_assert_eq "77" "${out%%|*}"
t_assert_contains "${out}" "SKIP [test-lacks.sh] this host lacks the frobnicator"

t_case "t_needs waives one case's failures on Git Bash, and only that case's; on Linux the case fails"
_suite one-case.sh 't_case waived
t_needs "the frobnicator" command -v no-such-frobnicator
t_assert_ok false
t_assert_ok true'
out="$(_run gitbash one-case.sh)"
t_assert_eq "0" "${out%%|*}"
t_assert_contains "${out}" "SKIP [waived] this host lacks the frobnicator"
t_assert_contains "${out}" "1 failed assertion(s) waived"
t_assert_contains "${out}" "2 assertion(s) passed"
out="$(_run linux one-case.sh)"
t_assert_eq "1" "${out%%|*}"
t_assert_contains "${out}" "prerequisite missing: the frobnicator"
_suite next-case.sh 't_case waived
t_needs "the frobnicator" command -v no-such-frobnicator
t_case counted
t_assert_ok false'
out="$(_run gitbash next-case.sh)"
t_assert_eq "1" "${out%%|*}" "the next t_case must count its failures again"

t_case "the probes read the host: Linux has links, mode bits and a POSIX python3; Git Bash has none of them"
if _t_may_skip; then
  t_assert_fails t_posix_symlinks
  t_assert_fails t_posix_modes
  t_assert_fails t_posix_python
else
  t_assert_ok t_posix_symlinks
  t_assert_ok t_posix_modes
  t_assert_ok t_posix_python
fi

t_case "an ln -s that copies and a chmod that sets nothing read as missing, on any host"
mkdir -p "${_WORK}/copying"
printf '#!/usr/bin/env bash\n[ "$1" = -s ] && shift\ncp "$(dirname "$2")/$1" "$2"\n' > "${_WORK}/copying/ln"
printf '#!/usr/bin/env bash\nexit 0\n' > "${_WORK}/copying/chmod"
chmod +x "${_WORK}/copying/ln" "${_WORK}/copying/chmod"
_probe() { PATH="${_WORK}/copying:${PATH}" bash -c 'source "$1"; "$2"' _ "${TESTS_DIR}/test-harness.sh" "$1"; }
t_assert_fails _probe t_posix_symlinks
t_assert_fails _probe t_posix_modes

t_case "t_is_elf reads the magic, not the name"
t_fake_elf "${_WORK}/fake.so" 62
t_assert_ok t_is_elf "${_WORK}/fake.so"
t_assert_fails t_is_elf "${TESTS_DIR}/test-harness.sh"

# run-tests.sh sits in the fake tests dir too, where it globs only test-has.sh and test-lacks.sh.
t_case "run-tests.sh lists a skip on Git Bash and stays green, without counting it as run"
out="$(_run gitbash run-tests.sh)"
t_assert_eq "0" "${out%%|*}"
t_assert_contains "${out}" "skipped on this host: test-lacks.sh"
t_assert_contains "${out}" "passed (1 suites, 1 assertions)"

t_case "run-tests.sh on Linux fails the run when a suite cannot run"
out="$(_run linux run-tests.sh)"
t_assert_eq "1" "${out%%|*}"
t_assert_contains "${out}" "1 suite(s) failed: test-lacks.sh"

t_case "and a stray exit 77 on Linux is a failure too, not a quiet skip"
printf '#!/usr/bin/env bash\nexit 77\n' > "${_WORK}/tests/test-lacks.sh"
out="$(_run linux run-tests.sh)"
t_assert_eq "1" "${out%%|*}"

t_summary
