#!/usr/bin/env bash
# flutter_integration_smoke_test.sh against a stub curl serving a fixture site: the CSP host check and the shared shell check.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="$(cd "${TESTS_DIR}/../.." && pwd)/webserver/scripts/flutter_integration_smoke_test.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The stub serves ${work}/site/<path>: a missing file is a 404; -I prints the headers a wasm file needs.
mkdir -p "${work}/bin" "${work}/site/javascript" "${work}/site/css" "${work}/site/canvaskit"
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
  [ -f "${file}" ] || exit 0
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
{ printf '_flutter.buildConfig = {"engineRevision":"abc","useLocalCanvasKit":true};\n'; head -c 200 /dev/zero; } > "${work}/site/flutter_bootstrap.js"
: > "${work}/site/main.dart.wasm"
: > "${work}/site/canvaskit/canvaskit.wasm"
: > "${work}/site/canvaskit/skwasm.wasm"
printf '{"name": "Fixture"}\n' > "${work}/site/manifest.json"
for f in javascript/utils.js javascript/cookies.js javascript/init.js css/cookie.css css/loading_animation.css; do : > "${work}/site/${f}"; done
SHELL_MARKUP='<section id="cookie-notice"></section><div id="background-animation"></div><div class="loading"></div><link href="css/loading_animation.css"><script src="javascript/init.js"></script>'
printf '<html>%s</html>\n' "${SHELL_MARKUP}" > "${work}/site/index.html"

_smoke() { PATH="${work}/bin:${PATH}" SITE="${work}/site" bash "${SMOKE}" http://site; }

t_case "an app without a CSP passes: no host is required by default"
t_assert_rc 0 env -u REQUIRED_CSP_HOSTS bash -c "$(declare -f _smoke); work='${work}'; SMOKE='${SMOKE}'; _smoke"

t_case "a named host must be in the CSP"
t_assert_contains "$(REQUIRED_CSP_HOSTS='cdn.example' t_out _smoke)" "FAIL: cdn.example missing from CSP"

t_case "a build that loads its engine from Google's CDN fails"
cp "${work}/site/flutter_bootstrap.js" "${work}/local-bootstrap.js"
{ printf '_flutter.buildConfig = {"engineRevision":"abc"};\n'; head -c 200 /dev/zero; } > "${work}/site/flutter_bootstrap.js"
t_assert_contains "$(t_out _smoke)" "FAIL: flutter_bootstrap.js loads the engine from Google's CDN"
mv "${work}/local-bootstrap.js" "${work}/site/flutter_bootstrap.js"

t_case "and so does one without its engine files"
mv "${work}/site/canvaskit/skwasm.wasm" "${work}/skwasm.wasm"
t_assert_contains "$(t_out _smoke)" "FAIL: canvaskit/skwasm.wasm not served as application/wasm"
mv "${work}/skwasm.wasm" "${work}/site/canvaskit/skwasm.wasm"

t_case "the shared shell's markup is required"
printf '<html><div class="loading"></div></html>\n' > "${work}/site/index.html"
t_assert_contains "$(t_out _smoke)" "FAIL: index.html lacks id=\"background-animation\""

t_case "and each of its files must be served"
printf '<html>%s</html>\n' "${SHELL_MARKUP}" > "${work}/site/index.html"
mv "${work}/site/javascript/init.js" "${work}/init.js"
t_assert_contains "$(t_out _smoke)" "FAIL: javascript/init.js returned HTTP 404"
mv "${work}/init.js" "${work}/site/javascript/init.js"

LOCK="$(cd "${TESTS_DIR}/.." && pwd)/05-frameworks/flutter/fallback-fonts.lock"
FIRST_FONT="$(awk '!/^#/ && NF == 3 { sub("https://fonts.gstatic.com/s/", "", $3); print $3; exit }' "${LOCK}")"
FONT_ROWS="$(awk '!/^#/ && NF == 3' "${LOCK}" | wc -l | tr -d ' ')"
# _bootstrap <load call>: the local-engine bootstrap, ending in that _flutter.loader.load call.
_bootstrap() { { printf '_flutter.buildConfig = {"engineRevision":"abc","useLocalCanvasKit":true};\n'; head -c 200 /dev/zero; printf '\n%s\n' "$1"; } > "${work}/site/flutter_bootstrap.js"; }

t_case "CHECK_FALLBACK_FONTS: a bootstrap that names no fontFallbackBaseUrl fails"
_bootstrap '_flutter.loader.load();'
t_assert_contains "$(CHECK_FALLBACK_FONTS=1 t_out _smoke)" "FAIL: flutter_bootstrap.js sets no fontFallbackBaseUrl on this site (got '')"

t_case "and so does one that names Google's"
_bootstrap '_flutter.loader.load({config: {fontFallbackBaseUrl: "https://fonts.gstatic.com/s/"}});'
t_assert_contains "$(CHECK_FALLBACK_FONTS=1 t_out _smoke)" "(got 'https://fonts.gstatic.com/s/')"

t_case "a font of the lock the site does not serve fails, naming it"
_bootstrap '_flutter.loader.load({config: {fontFallbackBaseUrl: "fallback-fonts/"}});'
t_assert_contains "$(CHECK_FALLBACK_FONTS=1 t_out _smoke)" "FAIL: fallback-fonts/${FIRST_FONT} returned HTTP 404"

t_case "every font of the lock under the base passes"
for font in $(awk '!/^#/ && NF == 3 { sub("https://fonts.gstatic.com/s/", "", $3); print $3 }' "${LOCK}"); do
  mkdir -p "$(dirname "${work}/site/fallback-fonts/${font}")" && : > "${work}/site/fallback-fonts/${font}"
done
t_assert_contains "$(CHECK_FALLBACK_FONTS=1 t_out _smoke)" "PASS: all ${FONT_ROWS} locked fallback fonts served under fallback-fonts/"
t_assert_rc 0 env CHECK_FALLBACK_FONTS=1 PATH="${work}/bin:${PATH}" SITE="${work}/site" bash "${SMOKE}" http://site

t_summary
