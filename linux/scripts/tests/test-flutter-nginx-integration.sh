#!/usr/bin/env bash
# flutter-nginx-integration-test.sh with a stub engine, curl and smoke test: what it mounts, and that it always removes nginx.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HARNESS="$(cd "${TESTS_DIR}/../.." && pwd)/webserver/scripts/flutter-nginx-integration-test.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin" "${work}/build"
: > "${work}/build/index.html"
# The engine records each call; `run` answers a container id.
cat > "${work}/bin/engine" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${work}/calls.log"
[ "\$1" = run ] && echo cid-1
exit 0
STUB
printf '#!/usr/bin/env bash\nexit "${CURL_RC:-0}"\n' > "${work}/bin/curl"
printf '#!/usr/bin/env bash\nprintf "smoke %%s\n" "$1" >> "%s/calls.log"\nexit "${SMOKE_RC:-0}"\n' "${work}" > "${work}/smoke.sh"
chmod +x "${work}/bin/engine" "${work}/bin/curl" "${work}/smoke.sh"

_run() { PATH="${work}/bin:${PATH}" ENGINE=engine FLUTTER_SMOKE_TEST="${work}/smoke.sh" bash "${HARNESS}" "$@"; }

t_case "a passing smoke test passes, against the chosen port"
: > "${work}/calls.log"
t_assert_rc 0 _run "${work}/build" --port 18080
t_assert_grep "${work}/calls.log" '^smoke http://localhost:18080$'
t_case "nginx gets the build and the shared config, read-only"
t_assert_grep "${work}/calls.log" '^run -d -p 18080:8080 .*target=/usr/share/nginx/html,readonly .*flutter-nginx-local\.conf,target=/etc/nginx/conf\.d/default\.conf,readonly nginx:alpine$'
t_case "and is removed afterwards"
t_assert_grep "${work}/calls.log" '^rm -f cid-1$'

t_case "a failing smoke test fails the run and still removes nginx"
: > "${work}/calls.log"
t_assert_rc 3 env SMOKE_RC=3 bash -c "$(declare -f _run); work='${work}'; HARNESS='${HARNESS}'; _run '${work}/build'"
t_assert_grep "${work}/calls.log" '^rm -f cid-1$'

t_case "nginx that never answers fails the run, prints its logs and is removed"
: > "${work}/calls.log"
t_assert_rc 1 env CURL_RC=7 NGINX_READY_ATTEMPTS=1 bash -c "$(declare -f _run); work='${work}'; HARNESS='${HARNESS}'; _run '${work}/build'"
t_assert_grep "${work}/calls.log" '^logs cid-1$'
t_assert_grep "${work}/calls.log" '^rm -f cid-1$'
t_assert_no_grep "${work}/calls.log" '^smoke'

t_case "no build is a usage error, before any container starts"
: > "${work}/calls.log"
t_assert_rc 2 _run "${work}/nothing-here"
t_assert_no_grep "${work}/calls.log" '^run'

t_summary
