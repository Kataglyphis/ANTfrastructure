#!/usr/bin/env bash
# run_nerdctl_build with RUN_NERDCTL_LOG: BuildKit's output goes to the arch log, the chain log keeps a failure's tail only.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
t_source_functions "${TESTS_DIR}/../01-core/build-helpers.sh" run run_nerdctl_build || exit 1
append_buildkit_host_arg() { :; }

# A stand-in for nerdctl: prints five layer lines and exits with FAKE_RC.
printf '#!/usr/bin/env bash\nfor i in 1 2 3 4 5; do echo "LAYER ${i}"; done\nexit "${FAKE_RC:-0}"\n' > "${_work}/nerdctl"
chmod +x "${_work}/nerdctl"

t_case "success: BuildKit's output stays in the arch log, nothing reaches the chain log"
export RUN_NERDCTL_LOG="${_work}/arch.log"; : > "${_work}/arch.log"
out="$(run_nerdctl_build "${_work}/nerdctl" build -t x . 2>&1)"; rc=$?
t_assert_eq "0" "${rc}"
t_assert_eq "" "${out}"
t_assert_contains "$(cat "${_work}/arch.log")" "LAYER 5"

t_case "failure: the chain log shows the tail of the arch log, and the return code survives"
: > "${_work}/arch.log"
out="$(FAKE_RC=3 run_nerdctl_build "${_work}/nerdctl" build -t x . 2>&1)"; rc=$?
t_assert_eq "3" "${rc}"
t_assert_contains "${out}" "| LAYER 5"

t_case "without RUN_NERDCTL_LOG the output streams as before"
unset RUN_NERDCTL_LOG
out="$(run_nerdctl_build "${_work}/nerdctl" build -t x . 2>&1)"
t_assert_contains "${out}" "LAYER 1"

t_summary
