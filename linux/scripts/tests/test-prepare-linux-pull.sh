#!/usr/bin/env bash
# prepare-linux-ci-host's pull-image.sh: the exit code and duration it records are what pull-first's wait step trusts.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PULL="${TESTS_DIR}/../../../.github/actions/prepare-linux-ci-host/pull-image.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT
mkdir -p "${_tmp}/bin"

# <exit code> <seconds to sleep>: a docker that only knows `pull`.
_fake_docker() {
  printf '#!/usr/bin/env bash\nsleep %s\necho "fake docker $*"\nexit %s\n' "$2" "$1" > "${_tmp}/bin/docker"
  chmod +x "${_tmp}/bin/docker"
}

t_case "a pull that succeeds records exit 0 and its duration"
_fake_docker 0 0
out="$(PATH="${_tmp}/bin:${PATH}" bash "${PULL}" img:tag 3 60 "${_tmp}/ok" 2>&1)"; rc=$?
t_assert_eq 0 "${rc}" "the script's own exit code"
t_assert_contains "${out}" "Pulled img:tag"
t_assert_eq 0 "$(cat "${_tmp}/ok.rc")" "the recorded exit code"
t_assert_ok grep -Eq '^[0-9]+$' "${_tmp}/ok.seconds"

t_case "a pull that fails every attempt records exit 1 and an error, with no sleep after the last attempt"
_fake_docker 1 0
out="$(PATH="${_tmp}/bin:${PATH}" bash "${PULL}" img:tag 1 60 "${_tmp}/bad" 2>&1)"; rc=$?
t_assert_eq 1 "${rc}"
t_assert_contains "${out}" "::error::Failed to pull img:tag after 1 attempts"
case "${out}" in *retrying*) t_assert_eq "no retry line" "a retry line" "one attempt has nothing to retry" ;; *) t_assert_eq 1 1 ;; esac
t_assert_eq 1 "$(cat "${_tmp}/bad.rc")"

t_case "detached, the exit code appears only once the pull has ended"
_fake_docker 0 2
PATH="${_tmp}/bin:${PATH}" nohup bash "${PULL}" img:tag 1 60 "${_tmp}/bg" > "${_tmp}/bg.log" 2>&1 < /dev/null &
bg=$!
t_assert_fails test -f "${_tmp}/bg.rc"
wait "${bg}"
t_assert_eq 0 "$(cat "${_tmp}/bg.rc")"
t_assert_contains "$(cat "${_tmp}/bg.log")" "fake docker pull img:tag"

t_summary
