# shellcheck shell=bash
# The wrapper push leaves the arch's critical path. docs/linux-cross-builds.md#the-wrapper-push-runs-beside-the-next-build
[ -n "${_LIB_RUNTIME_PUSH_SH_LOADED:-}" ] && return 0
_LIB_RUNTIME_PUSH_SH_LOADED=1
# shellcheck source=linux/scripts/01-core/chain-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/01-core/chain-lifecycle.sh"

RUNTIME_PUSH_QUEUE_DIR=""
RUNTIME_PUSHER_PID=""

# Prints async or inline. An unknown value is rc 2, so a typo stops a lane at its start.
runtime_push_mode() {
  case "${RUNTIME_ASYNC_PUSH:-1}" in
    1) printf '%s' async ;;
    0) printf '%s' inline ;;
    *)
      printf '[ERROR] RUNTIME_ASYNC_PUSH=%s: expected 1 (background pusher) or 0 (inline push)\n' "${RUNTIME_ASYNC_PUSH}" >&2
      return 2
      ;;
  esac
}

# Call in the main shell before the arch loop: a worker subshell's pusher would outlive the shell that waits for it.
runtime_push_queue_start() {
  local mode
  mode="$(runtime_push_mode)" || return 2
  RUNTIME_PUSH_QUEUE_DIR=""
  RUNTIME_PUSHER_PID=""
  runtime_pushes_wrapper_images || return 0
  is_dry_run && return 0
  if [ "${mode}" = inline ]; then
    log "[runtime-push] RUNTIME_ASYNC_PUSH=0: each wrapper push blocks its arch's lane"
    return 0
  fi
  RUNTIME_PUSH_QUEUE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/runtime-push.XXXXXX")" || return 1
  _runtime_pusher_loop "${RUNTIME_PUSH_QUEUE_DIR}" "$$" &
  RUNTIME_PUSHER_PID=$!
  trap_push 'runtime_push_queue_finish exit'
  log "[runtime-push] background pusher pid ${RUNTIME_PUSHER_PID}: each wrapper uploads while the next arch builds (RUNTIME_ASYNC_PUSH=0 pushes inline)"
}

# <tag> <arch>: queue the wrapper push, or push inline when no pusher runs.
runtime_push_wrapper() {
  local tag="$1" arch="$2" item
  if [ -z "${RUNTIME_PUSH_QUEUE_DIR:-}" ] || [ ! -d "${RUNTIME_PUSH_QUEUE_DIR}" ]; then
    runtime_push_tag "${tag}"
    return
  fi
  item="q.$(date +%s%N).${arch}"
  printf '%s\n' "${tag}" > "${RUNTIME_PUSH_QUEUE_DIR}/.${item}" || return 1
  mv -f "${RUNTIME_PUSH_QUEUE_DIR}/.${item}" "${RUNTIME_PUSH_QUEUE_DIR}/${item}" || return 1
  log "[runtime-push] arch=${arch} queued epoch=$(date +%s) tag=${tag}"
}

# Oldest queued item, by the nanosecond stamp in its name.
_runtime_push_next() {
  local f oldest=""
  for f in "$1"/q.*; do
    [ -e "${f}" ] || continue
    f="${f##*/}"
    if [ -z "${oldest}" ] || [[ "${f}" < "${oldest}" ]]; then oldest="${f}"; fi
  done
  printf '%s' "${oldest}"
}

# <dir> <owner-pid>: FIFO, one push at a time, so the first queued arch gets the whole uplink.
_runtime_pusher_loop() {
  local dir="$1" owner="$2" poll="${RUNTIME_PUSH_POLL_SECS:-5}" item arch tag rc t0
  while :; do
    item="$(_runtime_push_next "${dir}")"
    if [ -n "${item}" ]; then
      arch="${item##*.}"
      tag="$(cat "${dir}/${item}")"
      mv -f "${dir}/${item}" "${dir}/started.${arch}"
      t0="$(date +%s)"
      log "[runtime-push] arch=${arch} start epoch=${t0} tag=${tag}"
      # rc is written inside the pipe: errexit would end this loop on a failed push. Prefixed, as it interleaves with the next build.
      { rc=0; runtime_push_tag "${tag}" 2>&1 || rc=$?; printf '%s\n' "${rc}" > "${dir}/rc.${arch}"; } \
        | sed -u "s/^/[push ${arch}] /"
      rc="$(cat "${dir}/rc.${arch}" 2>/dev/null || printf 'none')"
      log "[runtime-push] arch=${arch} done epoch=$(date +%s) secs=$(( $(date +%s) - t0 )) rc=${rc}"
      continue
    fi
    # Re-read after seeing closed: the last item may land between the two reads.
    if [ -e "${dir}/closed" ]; then
      [ -n "$(_runtime_push_next "${dir}")" ] || return 0
      continue
    fi
    kill -0 "${owner}" 2>/dev/null || return 0
    sleep "${poll}"
  done
}

# [exit]: close the queue, wait for every queued push, fail on any that did not land. Idempotent.
runtime_push_queue_finish() {
  local why="${1:-}" dir="${RUNTIME_PUSH_QUEUE_DIR:-}" t0 f arch rc failed="" n=0
  [ -n "${dir}" ] && [ -d "${dir}" ] || return 0
  # An interrupt stops the uploads; any other failure lets the wrappers already built land, as an inline push would have.
  if [ "${why}" = exit ] && [ "${_BH_RC:-0}" -ge 128 ] && [ -n "${RUNTIME_PUSHER_PID:-}" ]; then
    log "[runtime-push] interrupted (rc ${_BH_RC}): stopping the background pusher"
    chain_terminate_descendants TERM "${RUNTIME_PUSHER_PID}"
    kill -TERM "${RUNTIME_PUSHER_PID}" 2>/dev/null || true
  elif [ "${why}" = exit ]; then
    log "[runtime-push] the lane is exiting; the wrappers it built still finish uploading first"
  fi
  t0="$(date +%s)"
  : > "${dir}/closed"
  if [ -n "${RUNTIME_PUSHER_PID:-}" ]; then
    wait "${RUNTIME_PUSHER_PID}" 2>/dev/null || true
  fi
  for f in "${dir}"/started.* "${dir}"/q.*; do
    [ -e "${f}" ] || continue
    arch="${f##*.}"
    n=$(( n + 1 ))
    rc="$(cat "${dir}/rc.${arch}" 2>/dev/null || true)"
    [ "${rc}" = 0 ] || failed="${failed:+${failed} }${arch}(rc=${rc:-none})"
  done
  rm -rf "${dir}"
  RUNTIME_PUSH_QUEUE_DIR=""
  RUNTIME_PUSHER_PID=""
  log "[runtime-push] queue drained: ${n} push(es), waited $(( $(date +%s) - t0 ))s for them at the drain"
  [ -z "${failed}" ] && return 0
  warn "[runtime-push] wrapper push FAILED for: ${failed}"
  return 1
}
