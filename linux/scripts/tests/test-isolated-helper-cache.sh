#!/usr/bin/env bash
# Fake cache failures prove public fixture routing and raw compiler status, not real daemon health, cache hits or inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare ROOT work cache_output cache_status cache_case_output
_CACHE_FIXTURE_CASE=0
t_fixture_workspace_init work ROOT || exit 1
mkdir "${work}/bin"
export IH_REAL_CC IH_REAL_CXX
IH_REAL_CC="$(command -v cc)"
IH_REAL_CXX="$(command -v c++)"
cat > "${work}/bin/sccache" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'sccache 0.19.0\n' ;;
  --start-server|--stop-server) exit 0 ;;
  --show-stats)
    if [[ "$*" == *json* ]]; then printf '{"stats":{}}\n'; else printf 'Compile requests 2\n'; fi ;;
  *)
    printf 'cache-compile\n' >> "${IH_RECEIPT}"
    if [[ "${IH_CACHE_MODE}" == broken ]]; then
      printf 'sccache: error: failed to execute compile\nsccache: caused by: Compiler not supported: "failed to write temporary file"\n' >&2
      exit 2
    fi
    exec "$@" ;;
esac
EOF
cat > "${work}/bin/compiler" <<'EOF'
#!/usr/bin/env bash
printf 'compiler %s\n' "${0##*/}" >> "${IH_RECEIPT}"
if [[ "${IH_COMPILER_STATUS}" != 0 ]]; then
  printf 'compiler: real fixture failure\n' >&2
  exit "${IH_COMPILER_STATUS}"
fi
compiler="${IH_REAL_CC}"
if [[ "${0##*/}" == c++ ]]; then compiler="${IH_REAL_CXX}"; fi
exec "${compiler}" "$@"
EOF
chmod +x "${work}/bin/sccache" "${work}/bin/compiler"
ln -s compiler "${work}/bin/cc"
ln -s compiler "${work}/bin/c++"

_cache_fixture_run() {
  local mode="$1" kind="$2" raw="$3" source_root="${4:-${ROOT}}" missing_api="${5:-0}" resolver_status="${6:-0}"
  _CACHE_FIXTURE_CASE=$((_CACHE_FIXTURE_CASE + 1))
  local output="${work}/case-${_CACHE_FIXTURE_CASE}" function
  cache_case_output="${output}"
  local -a args
  mkdir "${output}"
  if [[ "${kind}" == c ]]; then
    function=_ih_c_object
    args=("${source_root}" "${output}" fixture shared/native/isolated_helper.c fixture)
  else
    function=_ih_asan_object
    args=("${source_root}" "${output}" fixture shared/native/hip_probe_main.cpp)
  fi
  t_capture_command cache_output cache_status env -u SCCACHE_MULTILEVEL_CHAIN -u SCCACHE_SERVER_UDS -u SCCACHE_SERVER_PORT \
    USE_SCCACHE=1 USE_CCACHE=0 SCCACHE_DIR="${output}/cache" SCCACHE_S3_SECRET_FILE="${output}/no-secret" SCCACHE_CACHE_SIZE=1G \
    PATH="${work}/bin:${PATH}" IH_CACHE_MODE="${mode}" IH_COMPILER_STATUS="${raw}" \
    IH_RECEIPT="${output}/calls" IH_MISSING_API="${missing_api}" IH_RESOLVER_STATUS="${resolver_status}" bash -c '
      source "$1" || exit
      shift
      if [[ "$IH_MISSING_API" != 0 ]]; then
        source "$2/linux/scripts/01-core/common.sh" || exit
        unset -f "$IH_MISSING_API"
      fi
      if [[ "$IH_RESOLVER_STATUS" != 0 ]]; then
        source "$2/linux/scripts/01-core/common.sh" || exit
        compiler_cache_launcher() { return "$IH_RESOLVER_STATUS"; }
      fi
      result=0
      "$@" || result=$?
      printf "parent-address=%s\n" "${SCCACHE_SERVER_UDS:-UNSET}"
      exit "$result"
    ' _ "${ROOT}/linux/scripts/lib/isolated-helper-compile.sh" "${function}" "${args[@]}"
}

for kind in c cpp; do
  t_case "${kind}: guarded cache failure retries twice then runs the real compiler"
  _cache_fixture_run broken "${kind}" 0
  t_assert_eq 0 "${cache_status}"
  t_assert_ok test -s "${cache_case_output}/fixture.o"
  t_assert_eq 2 "$(grep -c '^cache-compile$' "${cache_case_output}/calls")"
  t_assert_contains "${cache_output}" 'compiling directly'
  t_assert_contains "${cache_output}" 'parent-address=/tmp/sccache-'
  t_assert_eq 'command_status=0' "$(head -n 1 "${cache_case_output}/fixture-cache/exit-status.txt")"
  t_case "${kind}: compiler failures retain their raw status without a direct retry"
  _cache_fixture_run ok "${kind}" 43
  t_assert_eq 43 "${cache_status}"
  t_assert_eq 1 "$(grep -c '^cache-compile$' "${cache_case_output}/calls")"
  t_assert_eq 'command_status=43' "$(head -n 1 "${cache_case_output}/fixture-cache/exit-status.txt")"
done

t_case 'missing required cache owner refuses before compilation'
_cache_fixture_run ok c 0 "${work}/missing-root"
t_assert_eq 1 "${cache_status}"
t_assert_contains "${cache_output}" 'common.sh'
for api in compiler_cache_launcher_env compiler_cache_launcher; do
  t_case "missing required ${api} export refuses before the compile command"
  _cache_fixture_run ok c 0 "${ROOT}" "${api}"
  t_assert_eq 1 "${cache_status}"
  t_assert_contains "${cache_output}" "Missing required compiler cache API: ${api}"
done
t_case 'cache resolver failures preserve their raw status before compilation'
_cache_fixture_run ok c 0 "${ROOT}" 0 63
t_assert_eq 63 "${cache_status}"
t_case 'a required source failure retains its raw status even when exports exist'
mkdir -p "${work}/failed-import/linux/scripts/01-core"
cat > "${work}/failed-import/linux/scripts/01-core/common.sh" <<'EOF'
compiler_cache_launcher_env() { :; }
compiler_cache_launcher() { printf '%s' /usr/bin/false; }
return 47
EOF
_cache_fixture_run ok c 0 "${work}/failed-import"
t_assert_eq 47 "${cache_status}"
t_summary
