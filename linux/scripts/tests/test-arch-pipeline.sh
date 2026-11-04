#!/usr/bin/env bash
# lib-chain-arch-pipeline.sh with a stub stage runner and registry, plus the real driver's dry run; not covered: a BuildKit build, a real image removal, disk accounting of a chain.
set -u
source "${BASH_SOURCE[0]%/*}/test-harness.sh"
t_private_tmpdir
source "${BASH_SOURCE[0]%/*}/meet.sh"
LIB="${_T_SCRIPTS}/lib-chain-arch-pipeline.sh"

# The stubs every section runs over the real library, the real loop and the real harvest.
_prelude() {
  cat <<'PRELUDE'
set -u
_bool_truthy() { [ "${1:-}" = 1 ]; }
log() { printf '%s\n' "$*" >> "${W}/log"; }
warn() { printf 'WARN %s\n' "$*" >> "${W}/log"; }
is_dry_run() { return 1; }
stage_enabled() { case "$1" in sdk|media|android) return 0 ;; esac; return 1; }
cross_stage_is_per_arch() { stage_enabled "$1"; }
cross_stage_tag() { printf 'repo:cross-%s-%s' "$1" "$2"; }
cross_stage_pin_varname() { printf '%s_PIN' "${1^^}"; }
arch_list_to_words() { printf '%s\n' amd64 arm64; }
_chain_status_emit() { printf '%s=%s\n' "$1" "$2" >> "${W}/status"; }
_disk_guard_free_gb() { cat "${W}/free" 2>/dev/null || echo 500; }
_disk_guard_positive_integer() { return 0; }
_disk_guard_protected_slugs() { printf 'chain-slugs'; }
_disk_guard_reclaim_begin() { :; }
_disk_guard_reclaim_record() { :; }
_disk_guard_buildkit_fallback() { printf 'buildkit\n' >> "${W}/calls"; }
_disk_guard_image_store_fallback() { printf 'image-store-fallback\n' >> "${W}/calls"; }
_disk_guard_nerdctl() { printf 'nerdctl %s\n' "$*" >> "${W}/calls"; }
_chain_evict_slugs() { printf 'evict protected=%s\n' "${!2}" >> "${W}/calls"; }
CROSS_STAGE_ORDER=(base compiler sdk media android runtime)
TARGET_ARCHES=amd64,arm64 MAX_PARALLEL_ARCHS=4 PARALLEL_ARCHS=0
declare -A SDK_PIN=() MEDIA_PIN=() ANDROID_PIN=()
PRELUDE
  cat "${_T_SCRIPTS}/01-core/parallel-loop.sh" "${LIB}" "${_T_SCRIPTS}/tests/meet.sh"
  t_fn_src "${_T_SCRIPTS}/01-core/cross-stage-build.sh" parallel_loop_harvest
}

# <body>: runs in a child shell with W set to a fresh directory; the directory stays in ${W} for assertions.
_run() {
  W="$(mktemp -d)"
  RC=0
  { _prelude; printf '%s\n' "$1"; } > "${W}/script.sh"
  export W
  bash "${W}/script.sh" > "${W}/out" 2>&1 || RC=$?
}

W=""
# <title> <body>: the previous case's directory goes, then the body runs.
_case() {
  [ -z "${W}" ] || rm -rf "${W}"
  t_case "$1"
  _run "$2"
}
_green() { t_assert_eq 0 "${RC}" "$(cat "${W}/out" "${W}/log" 2>/dev/null)"; }
_says() { t_assert_contains "$(cat "${W}/out")" "$1"; }
_called() { t_assert_contains "$(cat "${W}/calls")" "$1"; }

_section_order() {
  _case "an arch's next stage starts while another arch is still in an earlier stage" 'cross_stage_run() {
  printf "%s %s\n" "$1" "$2" >> "${W}/ran"
  case "$1.$2" in
    media.amd64) [ "$(meet_peers "${W}" media-amd64 2 20)" = met ] || { printf "alone\n" >> "${W}/ran"; return 1; } ;;
    android.arm64) meet_peers "${W}" android-arm64 2 20 >/dev/null ;;
  esac
}
chain_arch_pipeline_run'
  _green
  t_assert_eq "" "$(grep -e alone "${W}/ran")" "android-arm64 ran beside media-amd64"
  t_assert_eq "sdk media android" "$(sed -n 's/ amd64$//p' "${W}/ran" | tr '\n' ' ' | sed 's/ $//')" "one arch keeps stage order"
  t_assert_eq "sdk=ok media=ok android=ok" "$(grep -e =ok "${W}/status" | tr '\n' ' ' | sed 's/ $//')" "every stage reports"
  _case "pins reach the parent shell and the next stage of the same lane" 'cross_stage_run() {
  local -n pin="${1^^}_PIN"
  case "$1" in media) [ "${SDK_PIN[$2]:-}" = "sdk@$2" ] || return 1 ;; android) [ "${MEDIA_PIN[$2]:-}" = "media@$2" ] || return 1 ;; esac
  pin["$2"]="$1@$2"
  printf "%s" "$1@$2" > "${PARALLEL_LOOP_FLAGDIR}/pin.$1.$2"
  : > "${PARALLEL_LOOP_FLAGDIR}/built.$1.$2"
}
chain_arch_pipeline_run
printf "%s %s %s\n" "${ANDROID_PIN[amd64]}" "${ANDROID_PIN[arm64]}" "${SDK_PIN[arm64]}"'
  _green
  _says "android@amd64 android@arm64 sdk@arm64"
  _case "the old PARALLEL_ARCHS value comes back for the runtime stage" 'cross_stage_run() { :; }
PARALLEL_ARCHS=7
chain_arch_pipeline_run
printf "after=%s\n" "${PARALLEL_ARCHS}"'
  _says "after=7"
  _case "a failed arch stops its own lane, the other finishes, and the run fails" 'cross_stage_run() {
  printf "%s %s\n" "$1" "$2" >> "${W}/ran"
  [ "$1.$2" != media.amd64 ] || return 1
}
chain_arch_pipeline_run && printf "green\n"'
  t_assert_eq 1 "${RC}" "$(cat "${W}/out")"
  t_assert_contains "$(cat "${W}/ran")" "android arm64"
  t_assert_eq "" "$(grep -e 'android amd64' "${W}/ran")" "amd64 stops at its failure"
  t_assert_eq "sdk=ok media=failed android=failed" "$(grep -e =ok -e =failed "${W}/status" | tr '\n' ' ' | sed 's/ $//')" "the status names what did not finish"
  _case "a lane that dies through a set -e exit is still recorded" 'cross_stage_run() { [ "$1.$2" != sdk.arm64 ] || exit 3; }
chain_arch_pipeline_run'
  t_assert_eq 1 "${RC}" "$(cat "${W}/out")"
  _case "the pipeline runs once, at the first per-arch stage, and leaves the shared stages alone" 'err() { printf "ERR %s\n" "$*"; exit 9; }
_chain_stage_disk_guard() { printf "guard %s\n" "$1" >> "${W}/calls"; }
cross_stage_run() { printf "%s %s\n" "$1" "$2" >> "${W}/ran"; }
CROSS_ARCH_PIPELINE=1
chain_arch_pipeline_takes base && printf "took-base\n"
chain_arch_pipeline_takes sdk && printf "took-sdk\n"
chain_arch_pipeline_takes media && printf "took-media\n"'
  _green
  t_assert_eq "" "$(grep -e took-base "${W}/out")" "base stays on the stage loop"
  _says "took-sdk"
  _says "took-media"
  t_assert_eq 6 "$(wc -l < "${W}/ran" | tr -d ' ')" "two arches, three stages, once"
  t_assert_eq "guard android" "$(cat "${W}/calls")" "the joined guard runs once, on the last stage"
  _case "a failed pipeline stops the chain" 'err() { printf "ERR %s\n" "$*"; exit 9; }
cross_stage_run() { return 1; }
CROSS_ARCH_PIPELINE=1
chain_arch_pipeline_takes sdk'
  t_assert_eq 9 "${RC}" "$(cat "${W}/out")"
}

_section_validate() {
  _case "off by default, and a typo stops the chain" 'chain_arch_pipeline_validate; printf "rc=%s\n" "$?"
chain_arch_pipeline_on && printf "on\n"
CROSS_ARCH_PIPELINE=yes chain_arch_pipeline_validate; printf "typo=%s\n" "$?"
CROSS_ARCH_PIPELINE=1 PARALLEL_STAGES=sdk chain_arch_pipeline_validate; printf "stages=%s\n" "$?"
CROSS_ARCH_PIPELINE=1 chain_arch_pipeline_validate; printf "good=%s\n" "$?"
CROSS_ARCH_PIPELINE=1 chain_arch_pipeline_on && printf "armed\n"'
  _says "rc=0"
  t_assert_eq "" "$(grep -x -e on "${W}/out")" "the default is the joined path"
  _says "typo=2"
  _says "stages=2"
  _says "good=0"
  _says "armed"
}

_section_disk() {
  _case "enough free space reclaims nothing" 'S="${W}/state"; mkdir "${S}"
_chain_lane_disk_guard media arm64 "${S}"'
  _green
  t_assert_eq "" "$(cat "${W}/calls" 2>/dev/null)" "above the floor"
  _case "low disk with no arch finished touches no image" 'echo 5 > "${W}/free"; S="${W}/state"; mkdir "${S}"
_chain_lane_disk_guard media arm64 "${S}"
printf "cache-export=%s\n" "${CROSS_NO_LOCAL_CACHE_EXPORT:-}"'
  _green
  _called "evict protected=chain-slugs"
  _called "buildkit"
  t_assert_eq "" "$(grep -e nerdctl -e image-store "${W}/calls")" "an image removal needs a finished arch"
  _says "cache-export=1"
  _case "low disk removes only a finished arch's earlier stages, never a prune" 'echo 5 > "${W}/free"; S="${W}/state"; mkdir "${S}"; : > "${S}/lane-done.amd64"
_chain_lane_disk_guard media arm64 "${S}"'
  _called "nerdctl rmi repo:cross-sdk-amd64"
  _called "nerdctl rmi repo:cross-media-amd64"
  t_assert_eq "" "$(grep -e android-amd64 -e arm64 -e prune -e image-store "${W}/calls")" "android is the runtime lane's, arm64 is building"
  _case "the image lever stops at the target and honours CROSS_IMAGE_PRUNE=0" 'echo 5 > "${W}/free"; S="${W}/state"; mkdir "${S}"; : > "${S}/lane-done.amd64"
_disk_guard_nerdctl() { printf "nerdctl %s\n" "$*" >> "${W}/calls"; echo 500 > "${W}/free"; }
_chain_lane_image_lever "${S}" /x 40'
  t_assert_eq 1 "$(grep -c -e 'nerdctl rmi' "${W}/calls")" "one removal reached the target"
  _run 'echo 5 > "${W}/free"; S="${W}/state"; mkdir "${S}"; : > "${S}/lane-done.amd64"
CROSS_IMAGE_PRUNE=0 _chain_lane_image_lever "${S}" /x 40'
  t_assert_eq "" "$(cat "${W}/calls" 2>/dev/null)" "the operator's switch holds"
  _case "one lane reclaims at a time, and the next reads the free space again" 'echo 5 > "${W}/free"; S="${W}/state"; mkdir "${S}"
flock() { printf "flock\n" >> "${W}/calls"; command flock "$@"; }
_chain_lane_reclaim() {
  mkdir "${W}/inside" || printf "overlap\n" >> "${W}/calls"
  for _ in {1..100}; do if [ -e "${W}/started.arm64" ] && [ -e "${W}/started.amd64" ]; then break; fi; sleep 0.1; done
  sleep 0.5
  printf "reclaim\n" >> "${W}/calls"
  rmdir "${W}/inside"
}
for lane in arm64 amd64; do
  { : > "${W}/started.${lane}"; _chain_lane_disk_guard media "${lane}" "${S}"; } &
done
wait'
  t_assert_eq 2 "$(grep -c -x reclaim "${W}/calls")" "$(cat "${W}/out")"
  t_assert_eq 2 "$(grep -c -x flock "${W}/calls")" "each lane takes the lock: a loaded host can separate the lanes in time, so overlap alone is no proof"
  t_assert_eq "" "$(grep -e overlap "${W}/calls")" "the lock serialises them"
  _case "a lane that gets the lock after enough was freed reclaims nothing" 'S="${W}/state"; mkdir "${S}"
_chain_lane_reclaim media arm64 "${S}" /x 40'
  t_assert_eq "" "$(cat "${W}/calls" 2>/dev/null)" "the previous holder freed enough"
  _case "the guard skips a dry run" 'is_dry_run() { return 0; }; echo 5 > "${W}/free"; S="${W}/state"; mkdir "${S}"
_chain_lane_disk_guard media arm64 "${S}"'
  t_assert_eq "" "$(cat "${W}/calls" 2>/dev/null)" "a dry run removes nothing"
}

_driver_dry() {
  [ -z "${W}" ] || rm -rf "${W}"
  W="$(mktemp -d)"
  ( cd "${W}" && env "$@" DISK_PREFLIGHT=0 CROSS_CHAIN_STATUS_FILE="${W}/status.json" \
    bash "${_T_SCRIPTS}/build-cross-chain.sh" --dry-run --log-dir '' --from-stage sdk --to-stage android --target-arches amd64,arm64 ) > "${W}/out" 2>&1
  RC=$?
}

_section_driver() {
  t_case "the real driver's dry run takes each arch through its stages"
  _driver_dry CROSS_ARCH_PIPELINE=1
  t_assert_eq 0 "${RC}" "$(tail -5 "${W}/out")"
  t_assert_contains "$(cat "${W}/out")" "[arch-pipeline] arch=arm64 stage=android done"
  t_assert_contains "$(cat "${W}/out")" "[arch-pipeline] arch=amd64 stage=sdk start"
  t_assert_contains "$(cat "${W}/status.json")" '"android": {"status": "ok"'
  t_case "without the switch the stage loop stays joined"
  _driver_dry CROSS_ARCH_PIPELINE=0
  t_assert_eq 0 "${RC}" "$(tail -5 "${W}/out")"
  t_assert_eq "" "$(grep -F -e '[arch-pipeline]' "${W}/out")" "the default path"
  t_case "a typo stops the driver before it builds"
  _driver_dry CROSS_ARCH_PIPELINE=later
  t_assert_eq 2 "${RC}" "$(tail -5 "${W}/out")"
}

t_sections _section_order _section_validate _section_disk _section_driver -- "$@"
[ -z "${W}" ] || rm -rf "${W}"
t_summary
