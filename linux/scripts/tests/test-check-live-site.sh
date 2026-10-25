#!/usr/bin/env bash
# check-live-site.js against fixture sites in headless Chrome: CSP blocks, third-party hosts, 404s, console errors, the file sweep and version.json. See docs/ftp-deploys.md#the-live-site-check
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless_chrome
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
CHECK="${SCRIPTS}/check-live-site.js"
w="$(mktemp -d)"
srv=""
_cleanup_live_site() {
  t_stop_children "${srv}"
  rm -rf "${w}"
}
trap _cleanup_live_site EXIT
export CHECK_LIVE_SITE_VIEWPORTS="800x600"

# _page <name> <csp or ''> <script>: a site whose page carries the app's <flutter-view> and runs <script>.
_page() {
  local d="${w}/site/$1" meta=""
  mkdir -p "${d}/assets"
  [ -n "$2" ] && meta="<meta http-equiv=\"Content-Security-Policy\" content=\"$2\">"
  # An icon link, or Chrome asks for /favicon.ico and that 404 fails every case.
  printf '<!DOCTYPE html><html><head><link rel="icon" href="data:,">%s</head><body><flutter-view></flutter-view><script>%s</script></body></html>\n' "${meta}" "$3" > "${d}/index.html"
  printf '{"app_name":"fixture","version":"1.0.0","build_number":"3"}\n' > "${d}/version.json"
  printf 'x' > "${d}/assets/data.txt"
}
CSP="default-src 'self'; script-src 'self' 'unsafe-inline'; connect-src 'self'"
_page clean "${CSP}" ''
_page csp "${CSP}" "fetch('https://fonts.gstatic.com/s/notocoloremoji/v32/x.0.woff2').catch(() => {});"
_page scroll "${CSP}" "addEventListener('wheel', () => fetch('https://fonts.gstatic.com/s/after-scroll.woff2').catch(() => {}), { once: true });"
_page broken '' "console.error('boom'); setTimeout(() => { throw new Error('kaput'); });"
_page missing '' "document.body.appendChild(Object.assign(document.createElement('img'), { src: 'missing.png' }));"
mkdir -p "${w}/site/blank"
printf '<!DOCTYPE html><html><head><link rel="icon" href="data:,"></head><body>no app</body></html>\n' > "${w}/site/blank/index.html"

node -e "require('${SCRIPTS}/check-docs-sidebars.js').serve('${w}/site').then((s) => require('fs').writeFileSync('${w}/port', String(s.address().port)))" &
srv=$!
for _ in $(seq 1 100); do [ -s "${w}/port" ] && break; sleep 0.1; done
PORT="$(cat "${w}/port" 2>/dev/null)"
t_skip_unless "the fixture server on a free port" test -n "${PORT}"
BASE="http://127.0.0.1:${PORT}"
# flaky fails on its first load only: the key is per page and the profile is fresh per run; always fails on every load.
_page flaky '' "const k = 'seen:' + location.pathname; if (!localStorage.getItem(k)) { localStorage.setItem(k, '1'); setTimeout(() => { throw new Error('once'); }); }"
_page always '' "setTimeout(() => { throw new Error('always'); });"
_page third '' "fetch('http://localhost:${PORT}/clean/version.json', { mode: 'no-cors' }).catch(() => {});"
_check() { node "${CHECK}" "$@" --scrolls 0 --settle-ms 300 --ready-ms 3000; }

t_case "a clean site passes: its routes, every file of the build and its version.json"
t_assert_rc 0 _check "${BASE}/clean/" / /#/about --files "${w}/site/clean"
t_assert_contains "$(t_out _check "${BASE}/clean/" /#/about --files "${w}/site/clean")" "ok   /#/about 800x600"
t_assert_contains "$(t_out _check "${BASE}/clean/" --files "${w}/site/clean")" "ok   3 files of ${w}/site/clean, 0 not served with 200"

t_case "a fetch the CSP blocks fails, with its full URL"
t_assert_rc 1 _check "${BASE}/csp/"
t_assert_contains "$(t_out _check "${BASE}/csp/")" "csp-blocked: connect-src https://fonts.gstatic.com/s/notocoloremoji/v32/x.0.woff2"

t_case "a request a scroll triggers is seen only with --scrolls"
t_assert_rc 0 _check "${BASE}/scroll/"
t_assert_contains "$(t_out node "${CHECK}" "${BASE}/scroll/" --scrolls 1 --settle-ms 300 --ready-ms 3000)" "csp-blocked: connect-src https://fonts.gstatic.com/s/after-scroll.woff2"

t_case "a host other than the site's fails unless --allow-host admits it"
t_assert_contains "$(t_out _check "${BASE}/third/")" "third-party host: localhost:${PORT}"
t_assert_rc 0 _check "${BASE}/third/" --allow-host "localhost:${PORT}"

t_case "a console error and an uncaught exception fail, on every route: each one boots the app afresh"
t_assert_contains "$(t_out _check "${BASE}/broken/")" "console.error: boom"
t_assert_contains "$(t_out _check "${BASE}/broken/")" "exception: Error: kaput"
t_assert_contains "$(t_out _check "${BASE}/broken/" / /#/other)" "FAIL /#/other 800x600"

t_case "a resource that answers 404 fails, naming it, and so does the console line it logs"
t_assert_contains "$(t_out _check "${BASE}/missing/")" "HTTP 404: ${BASE}/missing/missing.png"
t_assert_contains "$(t_out _check "${BASE}/missing/")" "console: Failed to load resource: the server responded with a status of 404"

t_case "a page without the app's view fails"
t_assert_contains "$(t_out _check "${BASE}/blank/")" "the app never started"

t_case "a built file the site does not serve fails; dotfiles are not swept"
cp -r "${w}/site/clean" "${w}/build"
printf 'x' > "${w}/build/only-here.png"
printf 'x' > "${w}/build/.htaccess"
t_assert_rc 1 _check "${BASE}/clean/" --files "${w}/build"
t_assert_contains "$(t_out _check "${BASE}/clean/" --files "${w}/build")" "404 only-here.png"
t_assert_contains "$(t_out _check "${BASE}/clean/" --files "${w}/build")" "FAIL 4 files of ${w}/build, 1 not served with 200"

t_case "version.json must be the build's, or --version's"
printf '{"version":"1.0.1","build_number":"3"}\n' > "${w}/build/version.json"
rm "${w}/build/only-here.png"
t_assert_contains "$(t_out _check "${BASE}/clean/" --files "${w}/build")" "FAIL version.json: 1.0.0+3, want 1.0.1+3"
t_assert_contains "$(t_out _check "${BASE}/clean/" --version 2.0.0)" "FAIL version.json: 1.0.0+3, want 2.0.0"
t_assert_rc 0 _check "${BASE}/clean/" --version 1.0.0+3

t_case "a route that fails once and passes on the retry passes, its first failure logged as flaky"
t_assert_rc 0 _check "${BASE}/" flaky/
t_assert_contains "$(t_out _check "${BASE}/" flaky/)" "flaky: flaky/ 800x600: exception: Error: once"
t_assert_contains "$(t_out _check "${BASE}/" flaky/)" "ok   (after a retry) flaky/ 800x600"

t_case "a route that fails on the retry too fails, with the retry's failure"
t_assert_rc 1 _check "${BASE}/" always/
t_assert_contains "$(t_out _check "${BASE}/" always/)" "FAIL always/ 800x600"
t_assert_contains "$(t_out _check "${BASE}/" always/)" "flaky: always/ 800x600: exception: Error: always"

t_case "a site that does not answer names each file's network error, not a status"
# Chrome rejects port 9 before the request can report ECONNREFUSED.
t_stop_children "${srv}"
srv=""
t_assert_contains "$(t_out node "${CHECK}" "${BASE}/" --files "${w}/site/clean" --scrolls 0 --settle-ms 0 --ready-ms 500)" "ECONNREFUSED index.html"

t_case "no base URL is a usage error"
t_assert_rc 2 node "${CHECK}"
t_assert_rc 2 node "${CHECK}" "${BASE}/clean/" --scrolls many

t_summary
