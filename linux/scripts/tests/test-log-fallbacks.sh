#!/usr/bin/env bash
# Copied logger fixtures cover bytes, lookup precedence and status, not real builds, downloads or payload copies.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/test-workspace-fixture.sh"
t_fixture_workspace_init WORK_ROOT
WORK="${WORK_ROOT}/logger fixtures"
ROOT="${_T_SCRIPTS}"
ORIGINAL="${1:-}"
mkdir -p "${WORK}/core" "${WORK}/lib" "${WORK}/frameworks/torch" "${WORK}/packaging" "${WORK}/bin" "${WORK}/flat" "${WORK}/base"
for tool in bash dirname; do ln -s "$(command -v "${tool}")" "${WORK}/base/${tool}"; done
for pair in '01-core/abseil-headers.sh core/abseil-headers.sh' 'lib/log-bootstrap.sh lib/log-bootstrap.sh'; do
  read -r source_path target <<<"${pair}"
  source_file="${ROOT}/${source_path}"
  [ -z "${ORIGINAL}" ] || source_file="${ORIGINAL}/${source_path##*/}"
  cp "${source_file}" "${WORK}/${target}"
done
source_file="${ORIGINAL:-${ROOT}/05-frameworks/torch}/build-app-wheelhouse.sh"
sed -n '/^TORCH_STAGING_DIR=""$/,/^require_host_python() {/p' "${source_file}" | sed '1d;$d' > "${WORK}/frameworks/torch/loggers.sh"
source_file="${ORIGINAL:-${ROOT}/06-packaging}/copy-media-payloads.sh"
sed '/^_dest() {/,$d' "${source_file}" > "${WORK}/packaging/loggers.sh"
: > "${WORK}/packaging/media-payloads.sh"
cp "${WORK}/packaging/"* "${WORK}/flat/"
cp "${WORK}/lib/log-bootstrap.sh" "${WORK}/flat/"
for name in info log warn err; do
  cat > "${WORK}/bin/${name}" <<'SH'
#!/usr/bin/env bash
IFS='|'
printf 'EXTERNAL %s:%s\n' "${0##*/}" "$*"
exit 8
SH
  chmod +x "${WORK}/bin/${name}"
done
cat > "${WORK}/worker.sh" <<'SH'
set -eu
source "$1"
work="$2" profile="$3" binding="$4" name="$5"
exec > "${work}/stdout" 2> "${work}/stderr"
export PATH="${work}/base"
download_file() { :; }
if [ "${binding}" = functions ]; then
  for symbol in info log warn err; do eval "$symbol() { printf 'PREBOUND $symbol:%s\n' \"\$*\"; return 7; }"; done
elif [ "${binding}" = partial ]; then
  warn() { printf 'PREBOUND warn:%s\n' "$*"; return 7; }
elif [ "${binding}" = external ]; then
  export PATH="${work}/bin:${PATH}"
fi
case "${profile}" in
  abseil) loader="${work}/core/abseil-headers.sh" ;;
  wheelhouse) loader="${work}/frameworks/torch/loggers.sh" ;;
  payload) loader="${work}/packaging/loggers.sh" ;;
  flat-payload) loader="${work}/flat/loggers.sh" ;;
  bootstrap) loader="${work}/lib/log-bootstrap.sh" ;;
esac
source "${loader}"
source "${loader}"
{
  printf '%s|%s|%s\n' "${_LOGGING_SH_LOADED:-absent}" "${_LOG_BOOTSTRAP_SH_LOADED:-absent}" "${_LOG_BOOTSTRAP_REGISTRAR_ONLY:-absent}"
  for symbol in info log warn err; do type -t "${symbol}" || printf 'absent\n'; done
} > "${work}/state"
IFS='|'
"${name}" 'literal %s $()' $'line\ntwo'
SH
diagnostic='' status=0
# Literal byte fixtures keep the expected severities independent of the registrar's renderer.
declare -A plain=([info]='[INFO] ' [log]='[INFO] ' [warn]='[WARN] ' [err]='[ERROR] ')
declare -A colored=([info]=$'\033[1;34m[INFO]\033[0m ' [log]=$'\033[1;34m[INFO]\033[0m ' [warn]=$'\033[1;33m[WARN]\033[0m ' [err]=$'\033[1;31m[ERROR]\033[0m ')
declare -A streams=([info]=stdout [log]=stdout [warn]=stderr [err]=stderr)
declare -A fallback_status=([info]=0 [log]=0 [warn]=0 [err]=1)
declare -A cold_scope=([abseil]=$'function\nabsent\nfunction\nabsent' [wheelhouse]=$'absent\nfunction\nfunction\nabsent' [payload]=$'absent\nabsent\nfunction\nabsent' [flat-payload]=$'absent\nabsent\nfunction\nabsent' [bootstrap]=$'function\nabsent\nfunction\nfunction')
for profile in abseil wheelhouse payload flat-payload bootstrap; do
  case "${profile}" in
    abseil) names='info warn' ;;
    wheelhouse) names='log warn' ;;
    payload|flat-payload) names=warn ;;
    bootstrap) names='info warn err' ;;
  esac
  for binding in none functions partial external; do
    for name in ${names}; do
      t_case "${profile}/${binding}/${name}"
      NO_COLOR=1 LOG_COLOR=never t_capture_command diagnostic status t_run_fixture_worker "${WORK}/worker.sh" "${WORK}" "${profile}" "${binding}" "${name}"
      stdout="$(cat "${WORK}/stdout"; printf '.')"
      stderr="$(cat "${WORK}/stderr"; printf '.')"
      state="$(cat "${WORK}/state")"
      expected_stdout='.' expected_stderr='.' expected_status=0
      message=$'literal %s $()|line\ntwo'
      if [ "${binding}" = functions ] || { [ "${binding}" = partial ] && [ "${name}" = warn ]; }; then
        expected_stdout="PREBOUND ${name}:${message}"$'\n.'; expected_status=7
      elif [ "${binding}" = external ] && [ "${profile}" != bootstrap ]; then
        expected_stdout="EXTERNAL ${name}:${message}"$'\n.'; expected_status=8
      else
        expected_status="${fallback_status[${name}]}"
        expected="${plain[${name}]}${message}"$'\n.'
        [ "${profile}" != bootstrap ] || expected="${colored[${name}]}${message}"$'\n.'
        if [ "${streams[${name}]}" = stderr ]; then expected_stderr="${expected}"; else expected_stdout="${expected}"; fi
      fi
      t_assert_eq "${expected_status}" "${status}"
      t_assert_eq "${expected_stdout}" "${stdout}"
      t_assert_eq "${expected_stderr}" "${stderr}"
      t_assert_eq '' "${diagnostic}"
      guard=absent
      [ "${profile}" != bootstrap ] || guard=1
      expected_scope="${cold_scope[${profile}]}"
      if [ "${binding}" = functions ]; then expected_scope=$'function\nfunction\nfunction\nfunction'; fi
      if [ "${binding}" = external ]; then
        expected_scope=$'file\nfile\nfile\nfile'
        [ "${profile}" != bootstrap ] || expected_scope=$'function\nfile\nfunction\nfunction'
      fi
      t_assert_eq "absent|${guard}|absent"$'\n'"${expected_scope}" "${state}" "the import preserves guards, its selector and public logger names"
      t_record_fixture_receipt "${RECEIPT:-}" "${profile}" "${binding}" "${name}" "${status}" "${stdout}" "${stderr}" "${state}"
    done
  done
done
t_case 'normal bootstrap ignores inherited application arguments'
t_assert_ok bash -uc 'loader="$1"; set -- --fallbacks-only; source "${loader}"; declare -F info >/dev/null && declare -F warn >/dev/null && declare -F err >/dev/null' _ "${WORK}/lib/log-bootstrap.sh"
if [ -z "${ORIGINAL}" ]; then
  for stage in toolchain media; do
    t_case "${stage} ships the shared logger beside its core modules"
    t_assert_ok grep -qF 'COPY --chmod=755 linux/scripts/lib/log-bootstrap.sh /opt/scripts/lib/log-bootstrap.sh' "${ROOT}/../Dockerfile.${stage}"
  done
  rm "${WORK}/lib/log-bootstrap.sh" "${WORK}/flat/log-bootstrap.sh"
  for profile in abseil wheelhouse payload flat-payload; do
    t_case "${profile} requires its copied logging companion"
    t_capture_command diagnostic status t_run_fixture_worker "${WORK}/worker.sh" "${WORK}" "${profile}" none warn
    t_assert_eq 1 "${status}"
    t_assert_contains "$(cat "${WORK}/stderr")" log-bootstrap.sh
  done
fi
t_summary
