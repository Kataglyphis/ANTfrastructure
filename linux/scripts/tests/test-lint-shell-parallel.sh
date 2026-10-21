#!/usr/bin/env bash
# lint-shell.sh runs one shellcheck per file side by side: same verdict as in turn, and a runner that dies cannot read as clean.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../lint-shell.sh"
PIN="$(sed -n 's/^SHELLCHECK_VERSION=v\{0,1\}//p' "${TESTS_DIR}/../01-core/tool-pins.env")"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# A PATH shellcheck at the pin: a file named bad-* fails, kill-* kills its runner, every check sleeps the secs file's value.
mkdir -p "${_work}/bin" "${_work}/src"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo "version: %s"; exit 0; }\nsleep "$(cat %s)"\ncase "${@: -1}" in *kill-*) kill -9 "$PPID" ;; *bad-*) exit 1 ;; esac\nexit 0\n' \
  "${PIN}" "${_work}/secs" > "${_work}/bin/shellcheck"
echo 0 > "${_work}/secs"
chmod +x "${_work}/bin/shellcheck"
for f in a b c d bad-1 bad-2; do printf '#!/usr/bin/env bash\ntrue\n' > "${_work}/src/${f}.sh"; done

# _lint [VAR=VAL...] -- <files...>: rc, then the output.
_lint() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  local out rc
  out="$(env PATH="${_work}/bin:${PATH}" ${envs[@]+"${envs[@]}"} bash "${SUBJECT}" "$@" 2>&1)"; rc=$?
  printf 'RC=%s\n%s\n' "${rc}" "${out}"
}
_all=("${_work}"/src/*.sh)

t_case "side by side or in turn, the failing files are the same and the gate fails"
par="$(_lint LINT_SHELL_JOBS=4 -- "${_all[@]}")"
ser="$(_lint LINT_SHELL_JOBS=1 -- "${_all[@]}")"
t_assert_contains "${par}" "RC=1"
t_assert_contains "${par}" "found 2 file(s) with error-level findings"
t_assert_eq "$(printf '%s\n' "${ser}" | grep 'bad-')" "$(printf '%s\n' "${par}" | grep 'bad-')" "both runs name the same files"
t_assert_contains "$(printf '%s\n' "${par}" | grep 'bad-' | tr '\n' ' ')" "bad-1.sh"

t_case "clean files pass and the count names every file"
t_assert_contains "$(_lint LINT_SHELL_JOBS=4 -- "${_work}"/src/[abcd].sh)" "shellcheck -S error clean (4 file(s))"

t_case "the files really are checked side by side"
_t0="$(date +%s)"
echo 2 > "${_work}/secs"
_lint LINT_SHELL_JOBS=4 -- "${_work}"/src/[abcd].sh >/dev/null
_par_secs="$(( $(date +%s) - _t0 ))"
_t0="$(date +%s)"
_lint LINT_SHELL_JOBS=1 -- "${_work}"/src/[abcd].sh >/dev/null
t_assert_ok test "${_par_secs}" -le "$(( $(date +%s) - _t0 - 6 ))"
echo 0 > "${_work}/secs"

t_case "a runner that dies early is refused, never graded clean"
printf '#!/usr/bin/env bash\ntrue\n' > "${_work}/src/kill-me.sh"
out="$(_lint LINT_SHELL_JOBS=1 -- "${_work}"/src/[ab].sh "${_work}/src/kill-me.sh" "${_work}"/src/[cd].sh)"
t_assert_contains "${out}" "RC=1"
t_assert_contains "${out}" "refusing to grade an incomplete run"

t_case "a jobs value that is not a positive integer is an error"
t_assert_contains "$(_lint LINT_SHELL_JOBS=0 -- "${_work}/src/a.sh")" "LINT_SHELL_JOBS=0 is not a positive integer"

t_summary
