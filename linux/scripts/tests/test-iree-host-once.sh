#!/usr/bin/env bash
# _iree_build_host_stage_once across concurrent lanes with a stub cmake; not covered: BuildKit's cache mount, a real LLVM build or running the shared tools.
set -u
source "${BASH_SOURCE[0]%/*}/test-harness.sh"
SUBJECT="${_T_SCRIPTS}/05-frameworks/torch/iree-wheelhouse.sh"

_lane_script() {
  local fn
  for fn in _iree_host_cmake_args _iree_failure_log _iree_host_required_tools _iree_build_host_stage \
    _iree_host_stage_key _iree_host_stage_restore _iree_host_stage_publish _iree_host_stage_evict _iree_build_host_stage_once; do
    t_fn_src "${SUBJECT}" "${fn}"
  done
  cat <<'BODY'
log() { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
BUILD_PYTHON=/bin/true MAX_JOBS=1 IREE_CROSS_BUILD_COMPILER="${IREE_CROSS_BUILD_COMPILER:-OFF}" IREE_VERSION="${IREE_VERSION:-v1}"
ccache_cmake_args=()
root="$1"; src_dir="${root}/src"; host_build="${root}/host"; host_install="${host_build}/install"
host_cc="${HOST_CC:-/bin/echo}" host_cxx=/bin/echo
mkdir -p "${root}" "${src_dir}"
BODY
  printf "_iree_build_host_stage_once\n"
}

_setup() {
  W="$(mktemp -d)"
  mkdir -p "${W}/bin"
  cat > "${W}/bin/cmake" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--build*)
    printf 'build\n' >> "${WORK}/builds"
    [ -z "${CMAKE_MEET:-}" ] || sleep "${CMAKE_MEET}"
    [ -z "${CMAKE_DAEMON:-}" ] || { sleep "${CMAKE_DAEMON}" >/dev/null 2>&1 & }
    dir="$2"
    mkdir -p "${dir}/install/bin"
    for tool in iree-c-embed-data iree-flatcc-cli iree-tblgen; do
      printf '#!/bin/sh\n' > "${dir}/install/bin/${tool}"; chmod +x "${dir}/install/bin/${tool}"
    done
    [ -z "${CMAKE_FAIL_ONCE:-}" ] || [ -e "${WORK}/failed" ] || { : > "${WORK}/failed"; exit 7; }
    ;;
esac
exit 0
STUB
  chmod +x "${W}/bin/cmake"
  _lane_script > "${W}/lane.sh"
}

# <lane>: one lane; output in ${W}/<lane>.out, status in ${W}/<lane>.rc.
_lane() {
  local rc=0
  env PATH="${W}/bin:${PATH}" WORK="${W}" IREE_HOST_CACHE_DIR="${LANE_CACHE:-${W}/cache}" bash "${W}/lane.sh" "${W}/$1" > "${W}/$1.out" 2>&1 || rc=$?
  printf '%s' "${rc}" > "${W}/$1.rc"
}

_builds() { [ -f "${W}/builds" ] && wc -l < "${W}/builds" | tr -d ' ' || printf 0; }

_section_shared() {
  _setup
  t_case "two lanes at once compile the host stage once"
  CMAKE_MEET=2 _lane arm64 &
  local first=$!
  CMAKE_MEET=2 _lane riscv64 &
  local second=$!
  wait "${first}" "${second}"
  t_assert_eq 1 "$(_builds)" "$(cat "${W}/arm64.out" "${W}/riscv64.out")"
  t_assert_eq 0 "$(cat "${W}/arm64.rc")" "the first lane"
  t_assert_eq 0 "$(cat "${W}/riscv64.rc")" "the second lane"
  t_assert_contains "$(cat "${W}/arm64.out" "${W}/riscv64.out")" "reusing"
  t_assert_ok test -x "${W}/arm64/host/install/bin/iree-tblgen"
  t_assert_ok test -x "${W}/riscv64/host/install/bin/iree-tblgen"
  t_case "a later lane restores instead of building"
  _lane third
  t_assert_eq 1 "$(_builds)" "$(cat "${W}/third.out")"
  t_case "a staged publish leaves no partial entry behind"
  t_assert_eq "" "$(find "${W}/cache" -maxdepth 1 -name '*.??????' )"
  rm -rf "${W}"
}

_section_key() {
  _setup
  t_case "another IREE pin does not reuse the entry"
  _lane one
  IREE_VERSION=v2 _lane two
  t_assert_eq 2 "$(_builds)" "$(cat "${W}/two.out")"
  t_case "another compiler behind the same path does not reuse the entry"
  printf '#!/bin/sh\necho "cc ${CC_VERSION:-one}"\n' > "${W}/bin/host-cc"
  chmod +x "${W}/bin/host-cc"
  HOST_CC="${W}/bin/host-cc" _lane same
  t_assert_eq 3 "$(_builds)" "$(cat "${W}/same.out")"
  HOST_CC="${W}/bin/host-cc" CC_VERSION=two _lane three
  t_assert_eq 4 "$(_builds)" "$(cat "${W}/three.out")"
  t_case "another compiler mode does not reuse the entry"
  IREE_CROSS_BUILD_COMPILER=ON _lane four
  t_assert_eq 5 "$(_builds)" "$(cat "${W}/four.out")"
  rm -rf "${W}"
}

_section_failure() {
  _setup
  t_case "a failed first lane publishes nothing and the second builds"
  CMAKE_FAIL_ONCE=1 _lane one
  t_assert_eq 1 "$(cat "${W}/one.rc")" "the failure stays visible: $(cat "${W}/one.out")"
  _lane two
  t_assert_eq 0 "$(cat "${W}/two.rc")" "$(cat "${W}/two.out")"
  t_assert_eq 2 "$(_builds)" "the second lane built"
  rm -rf "${W}"
  _setup
  t_case "an entry that lost a tool is rebuilt"
  _lane one
  find "${W}/cache" -name iree-tblgen -delete
  _lane two
  t_assert_eq 2 "$(_builds)" "$(cat "${W}/two.out")"
  t_assert_contains "$(cat "${W}/two.out")" "lacks iree-tblgen"
  t_assert_eq 0 "$(cat "${W}/two.rc")" "the rebuild republished"
  _lane three
  t_assert_eq 2 "$(_builds)" "the rebuilt entry is whole"
  rm -rf "${W}"
}

_section_lock() {
  _setup
  t_case "a background child of the build does not hold the lock"
  CMAKE_DAEMON=20 _lane one
  IREE_HOST_LOCK_WAIT_SECS=3 _lane two
  t_assert_eq 1 "$(_builds)" "$(cat "${W}/two.out")"
  t_assert_contains "$(cat "${W}/two.out")" "reusing"
  t_case "a lane that cannot get the lock in time builds its own"
  ( flock 8; printf held > "${W}/held"; sleep 6 ) 8> "$(find "${W}/cache" -name '*.lock' | head -1)" &
  local holder=$!
  local i=0
  while [ ! -e "${W}/held" ] && [ "${i}" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
  IREE_HOST_LOCK_WAIT_SECS=1 _lane three
  t_assert_eq 2 "$(_builds)" "$(cat "${W}/three.out")"
  t_assert_contains "$(cat "${W}/three.out")" "too long"
  wait "${holder}"
  rm -rf "${W}"
}

_section_switch() {
  _setup
  t_case "IREE_HOST_CACHE=off builds in the lane"
  IREE_HOST_CACHE=off _lane one
  IREE_HOST_CACHE=off _lane two
  t_assert_eq 2 "$(_builds)" "$(cat "${W}/two.out")"
  t_assert_eq "" "$(ls -A "${W}/cache" 2>/dev/null)"
  t_case "a typo fails instead of silently building twice"
  IREE_HOST_CACHE=maybe _lane three
  t_assert_eq 2 "$(cat "${W}/three.rc")" "$(cat "${W}/three.out")"
  t_case "an unusable cache degrades to a build in the lane"
  : > "${W}/notadir"
  LANE_CACHE="${W}/notadir/x" _lane four
  t_assert_eq 0 "$(cat "${W}/four.rc")" "$(cat "${W}/four.out")"
  t_assert_contains "$(cat "${W}/four.out")" "not usable"
  rm -rf "${W}"
}

_section_wiring() {
  t_case "the cross path takes the shared stage, the media RUN mounts its cache"
  t_assert_contains "$(cat "${SUBJECT}")" "_iree_build_host_stage_once || return 1"
  t_assert_contains "$(sed -n '/kataglyphis.step=app-wheelhouse$/,/build-app-wheelhouse.sh/p' "${_T_SCRIPTS}/../Dockerfile.media")" "target=/var/cache/iree-host,id=iree-host"
}

t_sections _section_shared _section_key _section_failure _section_lock _section_switch _section_wiring -- "$@"
t_summary
