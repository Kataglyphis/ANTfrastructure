#!/usr/bin/env bash
# serve-stack.sh -- render, validate, start, reload and stop the llm-stack gateway.
# Commands, knobs and the reload contract: linux/llm-stack/README.md § Gateway.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$(cd "${HERE}/.." && pwd)"
RENDER="${STACK}/gateway/render_apisix.py"
OVERLAY="${STACK}/docker-compose.gateway.yml"
REGISTRY="${ANTFRASTRUCTURE_LLM_BACKENDS:-${STACK}/backends.json}"
PROJECT="${ANTFRASTRUCTURE_LLM_GATEWAY_PROJECT:-llm-gateway}"
STATE="${ANTFRASTRUCTURE_LLM_GATEWAY_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/antfrastructure/llm-gateway}"
export ANTFRASTRUCTURE_LLM_GATEWAY_DIR="${STATE}"
LIVE="${STATE}/live"
ENGINE=""
VALIDATE_NAME=""
# A candidate whose boot log matches this never goes live.
BAD_LOG='failed to check item data|invalid item data|failed to parse the content|failed to load plugin|failed to handle configuration|init_worker_by_lua error|init_by_lua error|geniex_hook: .* moved|\[emerg\]|\[crit\]|stack traceback|error loading module'
KEY_RE='^[A-Za-z0-9._~+/-]{16,}$'

die() { printf 'serve-stack: %s\n' "$*" >&2; exit 1; }
say() { printf 'serve-stack: %s\n' "$*"; }

cleanup() {
  if [ -n "${VALIDATE_NAME}" ]; then
    "${ENGINE}" rm -f "${VALIDATE_NAME}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: serve-stack.sh up | reload | down | status | keys | validate <bundle-dir>
  up        render + validate, then (re)start the gateway and wait until it serves the new config
  reload    render + validate, then swap apisix.json in place (no restart; routing changes only)
  down      stop and remove the gateway container
  status    what is running against what the registry renders now
  keys      write random client keys to $STATE/keys.env if it does not exist
  validate  boot an already rendered bundle in a throwaway container (no network)
EOF
}

pick_engine() {  # the knob, else the first of nerdctl and docker on PATH
  local name
  ENGINE="${ANTFRASTRUCTURE_LLM_ENGINE:-}"
  for name in nerdctl docker; do
    [ -z "${ENGINE}" ] || break
    if command -v "${name}" >/dev/null 2>&1; then ENGINE="${name}"; fi
  done
  [ -n "${ENGINE}" ] || die "no container engine: neither nerdctl nor docker is on PATH"
  command -v "${ENGINE}" >/dev/null 2>&1 || die "container engine '${ENGINE}' not found"
  command -v curl >/dev/null 2>&1 || die "curl is required"
}

compose() {
  "${ENGINE}" compose -p "${PROJECT}" -f "${OVERLAY}" "$@"
}

json_get() {  # json_get <file> <key>: one top-level field; a list prints one item per line
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    v = json.load(fh).get(sys.argv[2])
print("\n".join(v) if isinstance(v, list) else ("" if v is None else v))
PY
}

render_into() {  # render_into <dir>
  rm -rf "$1"
  mkdir -p "$1"
  python3 "${RENDER}" --registry "${REGISTRY}" --out "$1" >/dev/null
}

live_info() {  # live_info <key>: a field of the running gateway's /gateway/info, empty when down
  local listen body
  [ -f "${LIVE}/render.json" ] || return 0
  listen="$(json_get "${LIVE}/render.json" listen)"
  body="$(curl -fsS --max-time 3 "http://${listen}/gateway/info" 2>/dev/null)" || return 0
  printf '%s' "${body}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null \
    || true
}

wait_for_config() {  # wait_for_config <config_sha256> <seconds>: five answers in a row, so both workers
  local want="$1" deadline streak=0
  deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if [ "$(live_info config_sha256)" = "${want}" ]; then
      streak=$((streak + 1))
      if [ "${streak}" -ge 5 ]; then return 0; fi
    else
      streak=0
    fi
    sleep 0.3
  done
  return 1
}

start_validation() {  # start_validation <dir>: the candidate on the pinned image, --net=none
  local dir="$1" var
  local -a env_args=()
  while IFS= read -r var; do
    if [ -n "${var}" ]; then env_args+=(-e "${var}=validate-only-${var}"); fi
  done < <(json_get "${dir}/render.json" key_vars)
  mkdir -p "${dir}/validate-logs"
  chmod 0777 "${dir}/validate-logs"
  VALIDATE_NAME="${PROJECT}-validate-$$"
  "${ENGINE}" run -d --name "${VALIDATE_NAME}" --net=none -e APISIX_STAND_ALONE=true "${env_args[@]}" \
    -v "${dir}/config.yaml:/usr/local/apisix/conf/config.yaml:ro" \
    -v "${dir}/apisix.json:/usr/local/apisix/conf/apisix.json:ro" \
    -v "${dir}/lua:/usr/local/apisix/custom:ro" \
    -v "${dir}/validate-logs:/var/log/gateway" \
    "$(json_get "${dir}/render.json" image)" >/dev/null
}

validate_bundle() {  # validate_bundle <dir>: served its own /gateway/info, and a clean boot log
  local dir="$1" want port probe body="" logs
  want="$(json_get "${dir}/render.json" config_sha256)"
  port="$(json_get "${dir}/render.json" listen)"
  port="${port##*:}"
  probe="exec 3<>/dev/tcp/127.0.0.1/${port} && printf 'GET /gateway/info HTTP/1.0\r\nHost: v\r\n\r\n' >&3 && cat <&3"
  start_validation "${dir}"
  for _ in $(seq 1 60); do
    body="$("${ENGINE}" exec "${VALIDATE_NAME}" bash -c "${probe}" 2>/dev/null || true)"
    case "${body}" in *"${want}"*) break ;; esac
    sleep 0.5
  done
  sleep 1
  logs="$("${ENGINE}" logs "${VALIDATE_NAME}" 2>&1 || true)"
  "${ENGINE}" rm -f "${VALIDATE_NAME}" >/dev/null 2>&1 || true
  VALIDATE_NAME=""
  if printf '%s\n' "${logs}" | grep -E -e "${BAD_LOG}" >/dev/null; then
    printf '%s\n' "${logs}" | grep -E -e "${BAD_LOG}" | head -n 20 >&2 || true
    die "validation: the candidate's boot log has errors (above); nothing was changed"
  fi
  case "${body}" in
    *"${want}"*) say "validation: the candidate booted clean and served config ${want:0:12}" ;;
    *) printf '%s\n' "${logs}" | tail -n 20 >&2
       die "validation: the candidate never served its /gateway/info; nothing was changed" ;;
  esac
}

key_from_file() {  # key_from_file <file> <VAR>: its value; the file is read, never sourced
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n 1 | tr -d '\r' || true
}

write_runtime_env() {  # write_runtime_env <dir>: the keys and the status port, mode 600
  local dir="$1" var val port
  local -a lines=()
  local -A seen=()
  port="$(json_get "${dir}/render.json" status_listen)"
  lines+=("GW_STATUS_PORT=${port##*:}")
  while IFS= read -r var; do
    [ -n "${var}" ] || continue
    val="${!var:-}"
    if [ -z "${val}" ]; then val="$(key_from_file "${STATE}/keys.env" "${var}")"; fi
    [[ "${val}" =~ ${KEY_RE} ]] || die "${var}: unset, or not 16+ characters of [A-Za-z0-9._~+/-] (serve-stack.sh keys writes ${STATE}/keys.env)"
    [ -z "${seen[${val}]:-}" ] || die "${var} repeats another client's key"
    seen["${val}"]=1
    lines+=("${var}=${val}")
  done < <(json_get "${dir}/render.json" key_vars)
  mkdir -p "${LIVE}"
  ( umask 077; printf '%s\n' "${lines[@]}" > "${LIVE}/runtime.env" )
}

install_bundle() {  # install_bundle <dir> full|config: apisix.json in place, the mount keeps its inode
  local dir="$1"
  mkdir -p "${LIVE}" "${STATE}/logs"
  chmod 0755 "${STATE}" "${LIVE}"
  chmod 0777 "${STATE}/logs"
  cat "${dir}/apisix.json" > "${LIVE}/apisix.json"
  if [ "$2" = full ]; then
    cat "${dir}/config.yaml" > "${LIVE}/config.yaml"
    rm -rf "${LIVE}/lua"
    cp -R "${dir}/lua" "${LIVE}/lua"
  fi
  cp "${dir}/render.json" "${LIVE}/render.json"
  chmod -R a+rX "${LIVE}"
}

wait_next_second() {  # APISIX compares whole-second mtimes: never write twice in one second
  local mtime
  mtime="$(stat -c %Y "$1" 2>/dev/null || echo 0)"
  while [ "$(date +%s)" -le "${mtime}" ]; do sleep 0.2; done
}

cmd_up() {
  local cand="${STATE}/candidate" want
  render_into "${cand}" || die "the registry did not render (above); nothing was changed"
  validate_bundle "${cand}"
  write_runtime_env "${cand}"
  install_bundle "${cand}" full
  # compose echoes the container's environment, keys included: keep it in a private file.
  if ! ( umask 077; compose up -d --force-recreate > "${STATE}/compose.log" 2>&1 ); then
    tail -n 20 "${STATE}/compose.log" >&2 || true
    die "compose up failed; the full output is in ${STATE}/compose.log"
  fi
  want="$(json_get "${cand}/render.json" config_sha256)"
  if ! wait_for_config "${want}" 90; then
    compose logs --tail 30 2>&1 | tail -n 30 >&2 || true
    die "the gateway did not come up serving ${want:0:12}"
  fi
  say "up: http://$(json_get "${LIVE}/render.json" listen) serves config ${want:0:12}"
}

cmd_reload() {
  local cand="${STATE}/candidate" want running
  [ -f "${LIVE}/render.json" ] || die "nothing is installed yet: serve-stack.sh up"
  running="$(live_info restart_sha256)"
  [ -n "${running}" ] || die "the gateway is not answering: serve-stack.sh up"
  render_into "${cand}" || die "the registry did not render (above); nothing was changed"
  if [ "$(json_get "${cand}/render.json" restart_sha256)" != "${running}" ]; then
    die "the image, the boot config or the Lua changed; that needs a restart: serve-stack.sh up"
  fi
  want="$(json_get "${cand}/render.json" config_sha256)"
  if [ "$(live_info config_sha256)" = "${want}" ]; then
    say "reload: already serving ${want:0:12}"
    return 0
  fi
  validate_bundle "${cand}"
  cp "${LIVE}/apisix.json" "${LIVE}/apisix.json.prev"
  cp "${LIVE}/render.json" "${LIVE}/render.json.prev"
  wait_next_second "${LIVE}/apisix.json"
  install_bundle "${cand}" config
  if ! wait_for_config "${want}" 30; then
    wait_next_second "${LIVE}/apisix.json"
    cat "${LIVE}/apisix.json.prev" > "${LIVE}/apisix.json"
    cp "${LIVE}/render.json.prev" "${LIVE}/render.json"
    die "the gateway never served ${want:0:12}; the previous config is back in place"
  fi
  say "reload: serving ${want:0:12}"
}

cmd_down() {
  if [ ! -f "${LIVE}/runtime.env" ]; then
    mkdir -p "${LIVE}"
    ( umask 077; : > "${LIVE}/runtime.env" )
  fi
  compose down
  say "down"
}

cmd_status() {
  local cand="${STATE}/status-candidate" serving restart want rc=0
  printf 'state:    %s (project %s)\n' "${STATE}" "${PROJECT}"
  serving="$(live_info config_sha256)"
  restart="$(live_info restart_sha256)"
  printf 'serving:  %s\n' "${serving:-nothing answers}"
  if ! render_into "${cand}"; then
    say "status: the registry does not render (above)"
    return 1
  fi
  want="$(json_get "${cand}/render.json" config_sha256)"
  printf 'registry: %s\n' "${want}"
  if [ -z "${serving}" ]; then
    say "status: down"; rc=1
  elif [ "${restart}" != "$(json_get "${cand}/render.json" restart_sha256)" ]; then
    say "status: image, boot config or Lua differ: serve-stack.sh up"; rc=1
  elif [ "${serving}" != "${want}" ]; then
    say "status: routing differs: serve-stack.sh reload"; rc=1
  else
    say "status: in sync"
  fi
  return "${rc}"
}

cmd_keys() {
  local file="${STATE}/keys.env" var
  local -a lines=()
  if [ -f "${file}" ]; then
    say "keys: ${file} exists; not rewritten"
    return 0
  fi
  while IFS= read -r var; do
    if [ -n "${var}" ]; then
      lines+=("${var}=$(python3 -c 'import secrets; print(secrets.token_hex(24))')")
    fi
  done < <(python3 "${RENDER}" --registry "${REGISTRY}" --print-key-vars)
  [ "${#lines[@]}" -gt 0 ] || die "the registry names no client keys"
  mkdir -p "${STATE}"
  ( umask 077; printf '%s\n' "${lines[@]}" > "${file}" )
  say "keys: wrote ${#lines[@]} keys to ${file} (mode 600)"
}

main() {
  local cmd="${1:-}"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  case "${cmd}" in
    up|reload|down|status|validate) pick_engine ;;
    keys) ;;
    -h|--help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
  case "${cmd}" in
    up) cmd_up ;;
    reload) cmd_reload ;;
    down) cmd_down ;;
    status) cmd_status ;;
    keys) cmd_keys ;;
    validate) [ -n "${2:-}" ] || die "validate needs a rendered bundle directory"
              validate_bundle "$2" ;;
  esac
}

main "$@"
