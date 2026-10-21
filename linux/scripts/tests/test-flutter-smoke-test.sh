#!/usr/bin/env bash
# flutter_integration_smoke_test.sh against a stub curl serving a fixture site: the CSP host check and the shared shell check.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="$(cd "${TESTS_DIR}/../.." && pwd)/webserver/scripts/flutter_integration_smoke_test.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The stub serves ${work}/site/<path>: a missing file is a 404; -I prints the headers a wasm file needs.
mkdir -p "${work}/bin" "${work}/site/javascript" "${work}/site/css"
cat > "${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
fmt="" head=0 url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) fmt="$2"; shift 2 ;;
    -o) shift 2 ;;
    -I) head=1; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#http://site}"; path="${path#/}"; file="${SITE}/${path:-index.html}"
if [ "${head}" -eq 1 ]; then
  case "${path}" in *.wasm) printf 'Content-Type: application/wasm\r\n' ;; *) printf 'Content-Type: text/html\r\n' ;; esac
  exit 0
fi
case "${fmt}" in
  '%{http_code}') if [ -f "${file}" ]; then printf 200; else printf 404; fi ;;
  '%{size_download}') if [ -f "${file}" ]; then wc -c < "${file}" | tr -d ' '; else printf 0; fi ;;
  *) [ -f "${file}" ] && cat "${file}" ;;
esac
exit 0
STUB
chmod +x "${work}/bin/curl"
head -c 20000 /dev/zero > "${work}/site/main.dart.js"
head -c 200 /dev/zero > "${work}/site/flutter_bootstrap.js"
: > "${work}/site/main.dart.wasm"
printf '{"name": "Fixture"}\n' > "${work}/site/manifest.json"
for f in javascript/utils.js javascript/cookies.js javascript/init.js css/cookie.css css/loading_animation.css; do : > "${work}/site/${f}"; done
SHELL_MARKUP='<section id="cookie-notice"></section><div id="background-animation"></div><div class="loading"></div><link href="css/loading_animation.css"><script src="javascript/init.js"></script>'
printf '<html>%s</html>\n' "${SHELL_MARKUP}" > "${work}/site/index.html"

_smoke() { PATH="${work}/bin:${PATH}" SITE="${work}/site" bash "${SMOKE}" http://site; }

t_case "an app without a CSP passes with the host check emptied"
t_assert_rc 0 env REQUIRED_CSP_HOSTS='' bash -c "$(declare -f _smoke); work='${work}'; SMOKE='${SMOKE}'; _smoke"

t_case "unset, the host check requires the CanvasKit hosts"
t_assert_rc 1 env -u REQUIRED_CSP_HOSTS bash -c "$(declare -f _smoke); work='${work}'; SMOKE='${SMOKE}'; _smoke"

t_case "the shared shell's markup is required"
printf '<html><div class="loading"></div></html>\n' > "${work}/site/index.html"
t_assert_contains "$(REQUIRED_CSP_HOSTS='' t_out _smoke)" "FAIL: index.html lacks id=\"background-animation\""

t_case "and each of its files must be served"
printf '<html>%s</html>\n' "${SHELL_MARKUP}" > "${work}/site/index.html"
mv "${work}/site/javascript/init.js" "${work}/init.js"
t_assert_contains "$(REQUIRED_CSP_HOSTS='' t_out _smoke)" "FAIL: javascript/init.js returned HTTP 404"

t_summary
