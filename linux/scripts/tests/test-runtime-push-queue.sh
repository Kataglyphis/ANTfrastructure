#!/usr/bin/env bash
# The background wrapper pusher and the parallel runtime gates, with the push stubbed: docs/linux-cross-builds.md#the-wrapper-push-runs-beside-the-next-build
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/meet.sh"
SCRIPTS="${TESTS_DIR}/.."
LIB="${SCRIPTS}/lib-runtime-push.sh"
RBF="${SCRIPTS}/01-core/runtime-build-fns.sh"
BRM="${SCRIPTS}/build-runtime-manifest.sh"
BRA="${SCRIPTS}/build-runtime-artifacts.sh"
CHAIN="${SCRIPTS}/build-cross-chain.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# The real EXIT trap stack, so the drain sees the lane's exit code as it does in a lane.
_TRAP="declare -a _EXIT_TRAP_STACK=()"$'\n'"$(t_fn_src "${SCRIPTS}/01-core/build-helpers.sh" trap_push)" || exit 1

# PUSH_GATE=<arch> holds that arch's push until ${W}/release exists (120 s at most); PUSH_FAIL=<arch> fails it.
_STUBS='log() { printf "LOG %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
is_dry_run() { [ "${DRY_RUN:-0}" = 1 ]; }
runtime_pushes_wrapper_images() { [ "${PUSH_IMAGES:-1}" = 1 ]; }
runtime_push_tag() {
  printf "start %s\n" "$1" >> "${W}/pushes"
  if [ "${1##*-}" = "${PUSH_GATE:-none}" ]; then
    for _ in $(seq 1200); do [ -e "${W}/release" ] && break; sleep 0.1; done
  fi
  printf "end %s\n" "$1" >> "${W}/pushes"
  [ "${1##*-}" != "${PUSH_FAIL:-none}" ]
}'
# One lane process in a fresh ${W}: the stubs, the trap stack, the real lib, then $1.
_run() {
  rm -rf "${_work}/w"; mkdir -p "${_work}/w"
  printf '%s\n' "set -euo pipefail" "${_STUBS}" "${_TRAP}" "source $(printf '%q' "${LIB}")" "$1" > "${_work}/lane.sh"
  W="${_work}/w" RUNTIME_PUSH_POLL_SECS=1 TMPDIR="${_work}/w" bash "${_work}/lane.sh" 2>&1
}
# The first upload, held open until ${W}/release exists, has started.
_HELD='runtime_push_queue_start
runtime_push_wrapper repo:latest-amd64 amd64
for _ in $(seq 600); do grep -q "start repo:latest-amd64" "${W}/pushes" 2>/dev/null && break; sleep 0.1; done'
_starts_ends() { printf '%s\n' "$1" | grep -E "^(${2:-start|end}) " | tr '\n' ' ' | sed 's/ $//'; }

t_case "the knob: background by default, 0 is inline, anything else stops the lane"
t_assert_eq "async" "$(_run 'runtime_push_mode')"
t_assert_eq "inline" "$(RUNTIME_ASYNC_PUSH=0 _run 'runtime_push_mode')"
t_assert_contains "$(RUNTIME_ASYNC_PUSH=yes _run 'runtime_push_mode' || true)" "RUNTIME_ASYNC_PUSH=yes: expected 1"
t_assert_eq "2" "$(RUNTIME_ASYNC_PUSH=yes _run 'runtime_push_mode' >/dev/null 2>&1; echo $?)"

t_case "the queue refuses a bad knob before the first build"
_out="$(RUNTIME_ASYNC_PUSH=2 _run 'runtime_push_queue_start && echo "RC=0" || echo "RC=$?"; echo "DIR=[${RUNTIME_PUSH_QUEUE_DIR}]"')"
t_assert_contains "${_out}" "RC=2"
t_assert_contains "${_out}" "DIR=[]"

t_case "no pusher without wrapper pushes, on a dry run, or with RUNTIME_ASYNC_PUSH=0: the push stays inline"
for _env in PUSH_IMAGES=0 DRY_RUN=1 RUNTIME_ASYNC_PUSH=0; do
  _out="$(_run "export ${_env}
runtime_push_queue_start
echo \"DIR=[\${RUNTIME_PUSH_QUEUE_DIR}]\"
runtime_push_wrapper repo:latest-amd64 amd64
cat \"\${W}/pushes\"")"
  t_assert_contains "${_out}" "DIR=[]" "${_env} starts no pusher"
  t_assert_contains "${_out}" "end repo:latest-amd64" "${_env} pushes inline, before the call returns"
done

# The overlap a chain run must show: arm64 builds while amd64's upload is still streaming.
t_case "a queued push streams while the next arch builds, and the drain waits for it"
_out="$(PUSH_GATE=amd64 _run "${_HELD}"'
grep -q "end repo:latest-amd64" "${W}/pushes" && echo "AMD64-ENDED-EARLY" || echo "BUILD arm64 while amd64 pushes"
runtime_push_wrapper repo:latest-arm64 arm64
touch "${W}/release"
runtime_push_queue_finish; echo "FINISH-RC=$?"
cat "${W}/pushes"')"
t_assert_contains "${_out}" "BUILD arm64 while amd64 pushes" "the enqueue must return before the upload ends"
t_assert_contains "${_out}" "FINISH-RC=0"
t_assert_contains "${_out}" "queue drained: 2 push(es)"
t_assert_eq "start repo:latest-amd64 end repo:latest-amd64 start repo:latest-arm64 end repo:latest-arm64" \
  "$(_starts_ends "${_out}")" "FIFO and one at a time: the first arch built gets the whole uplink"
t_assert_contains "${_out}" "LOG [runtime-push] arch=amd64 start epoch="
t_assert_contains "${_out}" "LOG [runtime-push] arch=arm64 done epoch="

# Both land while the held push keeps the pusher from looking, so it sees them together.
t_case "items queued out of order still go oldest first"
_out="$(PUSH_GATE=amd64 _run "${_HELD}"'
printf "repo:latest-riscv64\n" > "${RUNTIME_PUSH_QUEUE_DIR}/.x"
printf "repo:latest-arm64\n" > "${RUNTIME_PUSH_QUEUE_DIR}/.y"
mv "${RUNTIME_PUSH_QUEUE_DIR}/.x" "${RUNTIME_PUSH_QUEUE_DIR}/q.2000000000000000000.riscv64"
mv "${RUNTIME_PUSH_QUEUE_DIR}/.y" "${RUNTIME_PUSH_QUEUE_DIR}/q.1000000000000000000.arm64"
touch "${W}/release"
runtime_push_queue_finish
cat "${W}/pushes"')"
t_assert_eq "start repo:latest-amd64 start repo:latest-arm64 start repo:latest-riscv64" "$(_starts_ends "${_out}" start)"

t_case "an item that lands between the empty read and the close is still pushed"
# The first read is forced empty, as if the enqueue came right after it; the pusher must look again once closed.
_out="$(_run '
mkdir -p "${W}/q"
printf "repo:latest-amd64\n" > "${W}/q/q.1000000000000000000.amd64"
: > "${W}/q/closed"
eval "_real_next() $(declare -f _runtime_push_next | tail -n +2)"
_runtime_push_next() { if [ ! -e "${W}/seen" ]; then : > "${W}/seen"; return 0; fi; _real_next "$@"; }
_runtime_pusher_loop "${W}/q" $$
cat "${W}/pushes"')"
t_assert_contains "${_out}" "end repo:latest-amd64"

t_case "a failed push fails the drain and names the arch; the next arch is still pushed"
_out="$(PUSH_FAIL=amd64 _run '
runtime_push_queue_start
runtime_push_wrapper repo:latest-amd64 amd64
runtime_push_wrapper repo:latest-arm64 arm64
runtime_push_queue_finish && echo "FINISH-RC=0" || echo "FINISH-RC=$?"
cat "${W}/pushes"')"
t_assert_contains "${_out}" "FINISH-RC=1"
t_assert_contains "${_out}" "wrapper push FAILED for: amd64(rc=1)"
t_assert_contains "${_out}" "end repo:latest-arm64" "one failed upload must not strand the queue behind it"
t_assert_contains "${_out}" "arch=amd64 done" "the loop survives the failure under errexit"

t_case "the drain is idempotent and a no-op without a queue"
_out="$(_run 'runtime_push_queue_finish; echo "RC1=$?"; runtime_push_queue_start; runtime_push_queue_finish; runtime_push_queue_finish; echo "RC2=$?"')"
t_assert_contains "${_out}" "RC1=0"
t_assert_contains "${_out}" "RC2=0"
t_assert_eq "1" "$(printf '%s\n' "${_out}" | grep -c 'queue drained' || true)"

t_case "a lane that fails still lets the wrappers it built land"
_out="$(PUSH_GATE=amd64 _run '
runtime_push_queue_start
runtime_push_wrapper repo:latest-amd64 amd64
( sleep 1; touch "${W}/release" ) &
exit 1' || true)"
t_assert_contains "${_out}" "the lane is exiting; the wrappers it built still finish uploading first"
t_assert_contains "${_out}" "arch=amd64 done"
t_assert_contains "${_out}" "queue drained: 1 push(es)"

t_case "an interrupt stops the pusher instead of waiting out the upload"
t_needs "pgrep, which the chain's own reaper needs too" command -v pgrep
if command -v pgrep >/dev/null 2>&1; then
  _t0="$(date +%s)"
  _out="$(PUSH_GATE=amd64 _run "${_HELD}"'
exit 130' || true)"
  t_assert_contains "${_out}" "interrupted (rc 130): stopping the background pusher"
  t_assert_contains "${_out}" "wrapper push FAILED for: amd64(rc=none)"
  t_assert_ok test "$(( $(date +%s) - _t0 ))" -lt 60
fi

t_case "the pusher stops once its owner is gone"
_out="$(_run '
_runtime_pusher_loop "${W}" 999999 &
p=$!
for _ in $(seq 300); do kill -0 "${p}" 2>/dev/null || break; sleep 0.1; done
kill -0 "${p}" 2>/dev/null && echo ALIVE || echo GONE
kill "${p}" 2>/dev/null || true')"
t_assert_contains "${_out}" "GONE"

# The wiring: the wrapper builds hand their push to the queue, and the index waits for it.
t_case "both wrapper ship steps push through the queue hook, which falls back inline"
for _fn in _runtime_ship_image _runtime_ship_rootfs; do
  _src="$(t_fn_src "${RBF}" "${_fn}")" || exit 1
  t_assert_contains "${_src}" '_runtime_push_wrapper_tag "${tag}" "${arch}" || return 1'
  t_assert_eq "0" "$(printf '%s\n' "${_src}" | grep -c 'runtime_push_tag' || true)" "${_fn} must not push past the queue"
done
_hook="$(t_fn_src "${RBF}" _runtime_push_wrapper_tag)" || exit 1
t_assert_eq "PUSHED x" "$(bash -c 'runtime_push_tag() { echo "PUSHED $1"; }'$'\n'"${_hook}"$'\n''_runtime_push_wrapper_tag x amd64')" \
  "without the lib the hook is the old inline push"

t_case "the manifest lane: queue before the loop, gates while it streams, drain before the index"
_build="$(t_fn_src "${BRM}" _manifest_build_and_smoke)" || exit 1
_order="$(printf '%s\n' "${_build}" | grep -E 'runtime_push_queue_start|run_parallel_arch_loop|_manifest_each_arch|runtime_push_queue_finish' \
  | sed 's/^ *//; s/ .*//' | tr '\n' ' ')"
t_assert_eq "runtime_push_queue_start run_parallel_arch_loop _manifest_each_arch _manifest_each_arch runtime_push_queue_finish " "${_order}"
_art="$(t_fn_src "${BRA}" main)" || exit 1
t_assert_contains "${_art}" 'runtime_push_queue_start || exit $?'
t_assert_contains "${_art}" 'runtime_push_queue_finish'
t_assert_contains "$(t_fn_src "${CHAIN}" _chain_validate_stages)" 'runtime_push_mode >/dev/null || exit 2' \
  "a typo stops the chain at its start, not at the runtime lane hours later"
t_assert_contains "$(cat "${SCRIPTS}/lib-orchestrator.sh")" 'source "${_LIB_ORCHESTRATOR_DIR}/lib-runtime-push.sh"'
t_assert_eq "" "$(grep -ln 'lib-runtime-push' "${SCRIPTS}"/../Dockerfile* 2>/dev/null || true)" \
  "no image closure holds the lib, so editing it re-keys no stage"

# The gate loops over a stub gate; GATE_FAIL names the arch whose gate fails, MEET where the gates meet.
_EACH="$(t_fn_src "${BRM}" _manifest_gate_jobs)"$'\n'"$(t_fn_src "${BRM}" _manifest_each_arch)"$'\n'"$(t_fn_src "${BRM}" _manifest_gates_parallel)" || exit 1
_GATE_STUBS="$(declare -f meet_peers)"'
set -euo pipefail
log() { printf "LOG %s\n" "$*"; }
warn() { printf "WARN %s\n" "$*"; }
arch_list_to_words() { printf "%s\n" "${1:-}" | tr ", " "\n\n"; }
TARGET_ARCHES="${ARCHES:-amd64,arm64,riscv64}"
_manifest_gate_arch() { printf "gate-%s line1\n" "$3"; [ -z "${MEET:-}" ] || meet_peers "${MEET}" "$3" 3 20 > "${MEET}/said.$3"; sleep 1; printf "gate-%s line2\n" "$3"; [ "$3" != "${GATE_FAIL:-none}" ]; }'
_gates() {
  printf '%s\n' "${_GATE_STUBS}" "${_EACH}" "$1" > "${_work}/gates.sh"
  TMPDIR="${_work}" bash "${_work}/gates.sh" 2>&1
}
# One content-gate phase; prints its output and EACH-RC=<rc>.
_each() { _gates "${1:-}"$'\n''_manifest_each_arch "content gate" /bin/gate.sh && echo EACH-RC=0 || echo "EACH-RC=$?"'; }
_gate_lines() { printf '%s\n' "$1" | grep '^gate-' | tr '\n' ' ' | sed 's/ $//'; }

# A rendezvous, never a wall-clock comparison: a loaded host slows both runs unevenly.
t_case "the gates run side by side, and each arch's output prints whole, in arch order"
mkdir -p "${_work}/meet"
_out="$(MEET="${_work}/meet" _each)"
t_assert_eq "met met met" "$(cat "${_work}/meet"/said.* | tr '\n' ' ' | sed 's/ $//')" "all three gates must be running at once"
t_assert_contains "${_out}" "EACH-RC=0"
t_assert_eq "gate-amd64 line1 gate-amd64 line2 gate-arm64 line1 gate-arm64 line2 gate-riscv64 line1 gate-riscv64 line2" \
  "$(_gate_lines "${_out}")"

t_case "one failing arch fails the phase, names it, and the others still finish"
_out="$(GATE_FAIL=arm64 _each)"
t_assert_contains "${_out}" "EACH-RC=1"
t_assert_contains "${_out}" "content gate FAILED for: arm64"
t_assert_contains "$(_gate_lines "${_out}")" "gate-riscv64 line2"

t_case "RUNTIME_GATE_JOBS=1 gates in turn and stops at the first failure, as before"
_out="$(RUNTIME_GATE_JOBS=1 GATE_FAIL=amd64 _each)"
t_assert_contains "${_out}" "EACH-RC=1"
t_assert_eq "gate-amd64 line1 gate-amd64 line2" "$(_gate_lines "${_out}")" "serial mode stops at the first red arch"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c 'runtime-gates' || true)" "and prints no parallel framing"

t_case "a bad RUNTIME_GATE_JOBS stops the phase; a cap is clamped to the arch count, and a lower one still gates all"
t_assert_contains "$(RUNTIME_GATE_JOBS=x _each)" "EACH-RC=2"
t_assert_contains "$(RUNTIME_GATE_JOBS=0 _each)" "EACH-RC=2"
t_assert_contains "$(RUNTIME_GATE_JOBS=9 _each)" "3 arch(es), 3 at a time"
_out="$(RUNTIME_GATE_JOBS=2 _each)"
t_assert_contains "${_out}" "3 arch(es), 2 at a time"
t_assert_eq "6 EACH-RC=0" "$(printf '%s\n' "${_out}" | grep -c '^gate-') $(printf '%s\n' "${_out}" | grep EACH-RC)"

t_case "a long-running background job (the pusher) does not hold the gates"
_t0="$(date +%s)"
_out="$(_each 'sleep 120 > /dev/null & _p=$!; trap "kill ${_p}" EXIT')"
t_assert_contains "${_out}" "EACH-RC=0"
t_assert_ok test "$(( $(date +%s) - _t0 ))" -lt 60

t_summary
