#!/usr/bin/env bash
# Isolated functions cover host suffixes, caller discovery, disk probes and built-state publication, not real builds or stores.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${1:-${TESTS_DIR}/../01-core}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cat > "${WORK}/worker.sh" <<'WORKER'
set -euo pipefail
source "$1"
source "$(dirname "$1")/shell-context-fixture.sh"
owner="$2"; scenario="$3"; fixture="$4"; mode="${5:-direct}"
if [ "${owner##*/}" = cross-stage-build.sh ]; then
  if grep -q '^_cross_stage_mark_built() {' "$owner"; then t_source_functions "$owner" _cross_stage_mark_built; fi
  t_source_functions "$owner" _cross_stage_run_capture_pin _cross_stage_record_local
else
  source "$owner"
fi
run_case() { eval "$scenario"; }
shell_fixture_run_context "$mode" case_status run_case
if [ "$mode" = conditional ]; then printf 'STATUS=%s\n' "$case_status"; else exit "$case_status"; fi
WORKER
_owner_run() {
  local owner="$1" scenario="$2" mode="${3:-direct}"
  bash "${WORK}/worker.sh" "${TESTS_DIR}/test-harness.sh" "${CORE}/${owner}.sh" "${scenario}" "${WORK}" "${mode}"
}

for arch in amd64 arm64 riscv64; do
  t_case "host suffixes for ${arch}"
  expected="-${arch}/-host${arch}"
  [ "${arch}" != amd64 ] || expected=/
  out="$(_owner_run tag-naming 'build_arch_oci() { printf "%s" "'"${arch}"'"; }; printf "%s/%s" "$(_cross_shared_tag_suffix)" "$(cross_build_host_infix)"')"
  t_assert_eq "${expected}" "${out}"
done
t_case 'missing host detector retains historical amd64 tags'
t_assert_eq / "$(_owner_run tag-naming 'unset -f build_arch_oci; printf "%s/%s" "$(_cross_shared_tag_suffix)" "$(cross_build_host_infix)"')"

mkdir -p "${WORK}/core" "${WORK}/01-core"
printf 'MODULE_MARK=loaded\n' > "${WORK}/local-fixture.sh"
for mode in direct conditional; do
  t_case "caller discovery ${mode}"
  out="$(_owner_run modules 'unset SCRIPT_DIR SCRIPTS_ROOT; source_modules_framework; source_module local-fixture.sh; printf "%s/%s/%s\n" "$SCRIPT_DIR" "$SCRIPTS_ROOT" "$MODULE_MARK"' "${mode}")"
  expected="${WORK}/${WORK}/loaded"
  [ "${mode}" != conditional ] || expected+=$'\nSTATUS=0'
  t_assert_eq "${expected}" "${out}"
done
t_case 'explicit caller paths retain trailing newline bytes'
mkdir -p "${WORK}/explicit"$'\n'
printf 'MODULE_MARK=explicit\n' > "${WORK}/explicit"$'\n/explicit-fixture.sh'
t_assert_eq explicit "$(_owner_run modules 'SCRIPT_DIR="$fixture/explicit"$'"'"'\n'"'"'; SCRIPTS_ROOT="$fixture/absent"; source_module explicit-fixture.sh; printf "%s" "$MODULE_MARK"')"

for target in '' invalid 0 10; do
  for free in '' 5 20; do
    t_case "disk target '${target}' free '${free}'"
    out="$(_owner_run disk-guard '_disk_guard_free_gb() { printf "probe\n" >&2; printf "%s" "'"${free}"'"; }; _disk_guard_log() { printf "LOG %s\n" "$*"; }; _disk_guard_warn() { printf "WARN %s\n" "$*"; }; _disk_guard_trim_cache_export() { printf "TRIM\n"; }; _disk_guard_buildkit_fallback() { :; }; _disk_guard_image_store_fallback() { :; }; _disk_guard_reclaim_record() { :; }; _disk_guard_watch_once unused "'"${target}"'"; printf "DONE\n"' 2> "${WORK}/err")"
    expected=DONE; probes=''
    case "${target}" in
      ''|invalid) : ;;
      *)
        probes=probe
        if [ -n "${free}" ]; then
          expected="LOG [disk-watch] ${free}G free on unused"
          if [ "${free}" -lt "${target}" ]; then expected+=$'\n'"WARN [disk-watch] ${free}G free < ${target}G DURING a stage — reclaiming regenerable cache exports now"$'\nTRIM'; fi
          expected+=$'\nDONE'
        fi ;;
    esac
    t_assert_eq "${expected}" "${out}"
    t_assert_eq "${probes}" "$(cat "${WORK}/err")"
  done
done

for action in local capture; do
  for state in scoped absent dry; do
    t_case "built publication ${action} ${state}"
    mkdir -p "${WORK}/flags"; rm -f "${WORK}/flags/"*
    out="$(_owner_run cross-stage-build 'log() { :; }; err() { printf "%s\n" "$*" >&2; exit 9; }; cross_stage_is_per_arch() { return 0; }; cross_stage_pin_varname() { printf MEDIA_PIN; }; retry() { printf sha256:fixture; }; is_dry_run() { [ "'"${state}"'" = dry ]; }; cross_local_handoff_enabled() { return 1; }; PARALLEL_LOOP_FLAGDIR="$fixture/flags"; if [ "'"${state}"'" != absent ]; then declare -A MEDIA_PIN=() MEDIA_BUILT_THIS_RUN=(); fi; if [ "'"${action}"'" = capture ]; then _cross_stage_run_capture_pin media arm64 label tag; else _cross_stage_record_local media arm64 label tag; fi; if [ "'"${state}"'" = absent ]; then printf "built=none pin=none\n"; else printf "built=%s pin=%s\n" "${MEDIA_BUILT_THIS_RUN[arm64]:-none}" "${MEDIA_PIN[arm64]:-none}"; fi')"
    expected='built=none pin=none'; marker=no; pin=no
    if [ "${state}" != absent ] && { [ "${action}" = capture ] || [ "${state}" != dry ]; }; then
      expected='built=1 pin=none'; marker=yes
      if [ "${action}" = capture ]; then expected='built=1 pin=sha256:fixture'; pin=yes; fi
    elif [ "${state}" = absent ] && [ "${action}" = local ]; then marker=yes
    fi
    t_assert_eq "${expected}" "${out}"
    actual=no; [ ! -f "${WORK}/flags/built.media.arm64" ] || actual=yes
    t_assert_eq "${marker}" "${actual}"
    actual=no; [ ! -f "${WORK}/flags/pin.media.arm64" ] || actual=yes
    t_assert_eq "${pin}" "${actual}"
  done
done
t_summary
