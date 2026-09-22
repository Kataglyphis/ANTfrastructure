#!/usr/bin/env bash
# linux/jetson-webcam: run.sh refuses a missing prerequisite by name, passes the
# three Jetson GPU flags, and app.py cannot stream on after inference died.
# Does NOT cover: the camera, the GPU or the model -- that is the README's run.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
DIR="${TESTS_DIR}/../../jetson-webcam"
RUN="${DIR}/run.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

t_case "a missing prerequisite stops run.sh with its name"
_out="$(HOME="${SANDBOX}" JETSON_WEBCAM_CAMERA=/nonexistent/video9 bash "${RUN}" 2>&1)"; _rc=$?
t_assert_eq 1 "${_rc}" "no camera, no container"
t_assert_contains "${_out}" "no camera at /nonexistent/video9"
touch "${SANDBOX}/cam"
_out="$(HOME="${SANDBOX}" JETSON_WEBCAM_CAMERA="${SANDBOX}/cam" bash "${RUN}" 2>&1)"; _rc=$?
t_assert_eq 1 "${_rc}" "no crun, no container"
t_assert_contains "${_out}" "${SANDBOX}/.local/bin/crun missing"

t_case "the container call carries the three Jetson GPU flags"
_call="$(sed -n '/^exec nerdctl/,/"\$@"$/p' "${RUN}")"
t_assert_contains "${_call}" '--cdi-spec-dirs "${CDI_DIR}"' "rootlesskit hides the toolkit's own spec dir"
t_assert_contains "${_call}" '--runtime "${CRUN}" --annotation run.oci.keep_original_groups=1' \
  "the video group the GPU and camera nodes belong to"
t_assert_contains "${_call}" '--device nvidia.com/gpu=all --device "${CAMERA}"'

t_case "a dead inference thread ends the process instead of streaming nothing"
t_assert_contains "$(sed -n '/^def run_or_die/,/^def main/p' "${DIR}/app.py")" "os._exit(1)"
t_assert_contains "$(sed -n '/^def main/,$p' "${DIR}/app.py")" "target=run_or_die"
t_assert_ok python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${DIR}/app.py"

t_summary
