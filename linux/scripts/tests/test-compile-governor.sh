#!/usr/bin/env bash
# sccache-launcher.sh's compile governor with real flock slots and concurrent launchers; not covered: BuildKit sharing the slot directory across builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LAUNCH="${TESTS_DIR}/../01-core/sccache-launcher.sh"

t_skip_unless "flock" command -v flock

W="$(mktemp -d)"
_pids=()
_cleanup() {
  local p
  for p in "${_pids[@]}"; do kill "${p}" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "${W}"
}
trap _cleanup EXIT
mkdir -p "${W}/bin" "${W}/run"

# A fake sccache that records how many compiles run at once, then holds for HOLD seconds.
cat > "${W}/bin/sccache" <<'EOF'
#!/bin/sh
: > "${RUN_DIR}/$$"
n="$(ls "${RUN_DIR}" | wc -l)"
echo "${n}" >> "${RUN_DIR}/../peaks"
echo "fake-sccache: diagnostic for $*" >&2
[ ! -e "${RUN_DIR}/../spawn-daemon" ] || { sleep 5 >/dev/null 2>&1 & }
sleep "${HOLD:-1}"
rm -f "${RUN_DIR}/$$"
exit 0
EOF
chmod +x "${W}/bin/sccache"
printf 'MemTotal:       64000000 kB\nMemAvailable:   %s kB\n' 40000000 > "${W}/meminfo-high"
printf 'MemTotal:       64000000 kB\nMemAvailable:   %s kB\n' 1000000 > "${W}/meminfo-low"

# _launch <count> [env...]: <count> concurrent launchers; echoes the peak concurrency and how many succeeded.
_launch() {
  local count="$1" i ok=0
  shift
  : > "${W}/peaks"; rm -f "${W}/run"/* "${W}/rc".*
  for ((i = 0; i < count; i++)); do
    ( env PATH="${W}/bin:${PATH}" RUN_DIR="${W}/run" KATAGLYPHIS_COMPILE_GOVERNOR_DIR="${W}/slots" KATAGLYPHIS_COMPILE_GOVERNOR_POLL=0.05 \
        KATAGLYPHIS_COMPILE_GOVERNOR_MEMINFO="${W}/meminfo-high" "$@" sh "${LAUNCH}" cc -c x.c >/dev/null 2>&1; echo "$?" > "${W}/rc.${i}" ) &
  done
  wait
  for ((i = 0; i < count; i++)); do [ "$(cat "${W}/rc.${i}" 2>/dev/null)" = 0 ] && ok=$((ok + 1)); done
  printf '%s %s' "$(sort -n "${W}/peaks" | tail -n 1)" "${ok}"
}

t_case "without the governor the fixture sees the compiles overlap"
read -r peak ok <<<"$(_launch 6 KATAGLYPHIS_COMPILE_GOVERNOR=off)"
t_assert_eq "6" "${ok}"
t_assert_ok test "${peak}" -gt 2

t_case "two slots hold six compiles to two at a time, and every compile still runs"
read -r peak ok <<<"$(_launch 6 KATAGLYPHIS_COMPILE_GOVERNOR_SLOTS=2)"
t_assert_eq "6" "${ok}"
t_assert_eq "2" "${peak}" "the cap"

t_case "low memory admits only slot 0, so the compiles run one by one"
read -r peak ok <<<"$(_launch 3 KATAGLYPHIS_COMPILE_GOVERNOR_SLOTS=4 KATAGLYPHIS_COMPILE_GOVERNOR_MEMINFO="${W}/meminfo-low")"
t_assert_eq "3" "${ok}"
t_assert_eq "1" "${peak}"

# _once <slot dir> [env...]: one launcher, output and status on stdout as "<rc>|<output>".
_once() {
  local dir="$1" out rc=0
  shift
  out="$(env PATH="${W}/bin:${PATH}" RUN_DIR="${W}/run" HOLD=0 KATAGLYPHIS_COMPILE_GOVERNOR_DIR="${dir}" \
    KATAGLYPHIS_COMPILE_GOVERNOR_POLL=0.05 KATAGLYPHIS_COMPILE_GOVERNOR_MEMINFO="${W}/meminfo-high" "$@" \
    sh "${LAUNCH}" cc -c x.c 2>&1)" || rc=$?
  printf '%s|%s' "${rc}" "${out}"
}

t_case "a governed compile still hands back the compiler's own messages"
rm -rf "${W}/slots"
_r="$(_once "${W}/slots" KATAGLYPHIS_COMPILE_GOVERNOR_SLOTS=2)"
t_assert_contains "${_r}" "0|fake-sccache: diagnostic for cc -c x.c"
t_assert_ok test -e "${W}/slots/slot.0"

t_case "a held slot past the wait limit warns and compiles ungoverned"
mkdir -p "${W}/held"
flock "${W}/held/slot.0" sleep 6 & _pids+=("$!")
sleep 0.3
_r="$(_once "${W}/held" KATAGLYPHIS_COMPILE_GOVERNOR_SLOTS=1 KATAGLYPHIS_COMPILE_GOVERNOR_MAX_WAIT=1)"
t_assert_contains "${_r}" "0|"
t_assert_contains "${_r}" "compiling ungoverned"

t_case "a server the client starts in the background does not keep the slot"
rm -rf "${W}/slots"
: > "${W}/spawn-daemon"
_once "${W}/slots" KATAGLYPHIS_COMPILE_GOVERNOR_SLOTS=1 >/dev/null
rm -f "${W}/spawn-daemon"
t_assert_ok flock -n "${W}/slots/slot.0" true

t_case "a slot file this uid cannot read is skipped, and the next slot is used"
rm -rf "${W}/slots"; mkdir -p "${W}/slots"; : > "${W}/slots/slot.0"; chmod 000 "${W}/slots/slot.0"
t_assert_contains "$(_once "${W}/slots" KATAGLYPHIS_COMPILE_GOVERNOR_SLOTS=2)" "0|fake-sccache: diagnostic"
chmod 600 "${W}/slots/slot.0"

t_case "an unwritable slot directory compiles as if there were no governor"
t_assert_contains "$(_once /proc/no-such-dir)" "0|fake-sccache: diagnostic"

t_summary
