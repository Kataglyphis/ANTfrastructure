#!/usr/bin/env bash
# run-in-ci-image.sh's --memory/--cpus caps and their RUN_IN_CI_IMAGE_* defaults, over a fake engine. See docs/shared-script-libraries.md#run-in-ci-imagesh--run-a-command-in-the-ci-image
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RUNNER="${TESTS_DIR}/../run-in-ci-image.sh"

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
mkdir -p "${w}/bin" "${w}/repo"
# The fake nerdctl answers every query with nothing and records the run's arguments.
cat > "${w}/bin/nerdctl" <<EOF
#!/usr/bin/env bash
[ "\$1" = run ] || exit 0
printf '%s\n' "\$*" > "${w}/run.args"
EOF
chmod +x "${w}/bin/nerdctl"

# _run [NAME=VALUE...] [runner options...]: one runner call over the fake engine, its stderr in ${w}/err.
_run() {
  local envs=()
  while [[ "${1:-}" == RUN_IN_CI_IMAGE_*=* ]]; do envs+=("$1"); shift; done
  rm -f "${w}/run.args"
  env -u RUN_IN_CI_IMAGE_MEMORY -u RUN_IN_CI_IMAGE_CPUS "${envs[@]}" bash "${RUNNER}" "${w}/repo" \
    --engine "${w}/bin/nerdctl" --image example/ci:latest "$@" -- true 2>"${w}/err"
}

t_case "both caps reach the run, with the swap limit at the memory limit"
_run --memory 6g --cpus 4
t_assert_grep "${w}/run.args" '--memory 6g --memory-swap 6g --cpus 4'
t_assert_grep "${w}/err" 'memory 6g, 4 cpus$'

t_case "the environment sets the caps a call does not name"
_run RUN_IN_CI_IMAGE_MEMORY=3g RUN_IN_CI_IMAGE_CPUS=2.5
t_assert_grep "${w}/run.args" '--memory 3g --memory-swap 3g --cpus 2.5'

t_case "an option overrides the environment"
_run RUN_IN_CI_IMAGE_MEMORY=3g --memory 8g
t_assert_grep "${w}/run.args" '--memory 8g --memory-swap 8g'
t_assert_no_grep "${w}/run.args" '--memory 3g'

t_case "without a cap the run carries none"
_run
t_assert_no_grep "${w}/run.args" '--memory'
t_assert_no_grep "${w}/run.args" '--cpus'

t_case "a malformed cap is refused before any engine call"
_run --memory lots
t_assert_eq 2 "$?" "--memory lots exits 2"
t_assert_eq 1 "$([ -e "${w}/run.args" ]; echo $?)" "no run after a refused --memory"
_run --cpus 0
t_assert_eq 2 "$?" "--cpus 0 exits 2"

t_summary
