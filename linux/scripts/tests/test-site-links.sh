#!/usr/bin/env bash
# verify_site_links.py over built fixture sites: every internal link and anchor resolves, offline. See docs/docs-sites.md#the-built-site-link-gate
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT
SITE_GATE="${TESTS_DIR}/../verify_site_links.py"

# _page <file> <body>: a whole HTML document under the current fixture site.
_page() {
  mkdir -p "$(dirname "${SITE}/$1")"
  printf '<!DOCTYPE html>\n<html><head><title>t</title></head><body>\n%s\n</body></html>\n' "$2" > "${SITE}/$1"
}

# _site <name>: a fresh fixture site that resolves completely; cases add one defect each.
_site() {
  SITE="${_WORK}/$1/site"
  mkdir -p "${SITE}/sub" "${SITE}/_static" "${SITE}/src"
  _page index.html '<a href="a.html">a</a> <a href="a.html#sec">sec</a> <a href="sub/">sub</a> <a href="sub">sub2</a>
<link rel="stylesheet" href="_static/x.css?v=1"> <a href="https://example.org/x.html">ext</a> <a href="mailto:x@y.z">m</a>
<a href="#">top</a> <a href="#top">top2</a> <a href="/a.html">abs</a> <a href="src/lib.rs.html#2-4">lines</a>
<a href="a.html#impl-From%3CT%3E-for-T">raw</a> <a href="a.html#%C3%BCber">decoded</a>'
  _page a.html '<h2 id="sec">s</h2><span id="impl-From%3CT%3E-for-T"></span><h3 id="über">u</h3>'
  _page sub/index.html '<a href="../a.html">up</a>'
  _page src/lib.rs.html '<a id="1">1</a><a id="2">2</a><a id="3">3</a><a id="4">4</a>'
  echo 'body{}' > "${SITE}/_static/x.css"
}

_gate() { "${PREFLIGHT_PYTHON:-python3}" "${SITE_GATE}" "$@"; }

t_case "a site whose every link resolves passes"
_site clean
t_assert_ok _gate "${SITE}"
t_assert_contains "$(t_out _gate "${SITE}")" "OK: every internal link and anchor resolves"
t_assert_contains "$(t_out _gate "${SITE}")" "4 documents"

t_case "a link to a page that is not there fails, and names the page that carries it"
_site missing
_page b.html '<a href="nope.html">x</a>'
t_assert_fails _gate "${SITE}"
t_assert_contains "$(t_out _gate "${SITE}")" "missing  nope.html   <- b.html"

t_case "an anchor the target page does not define fails"
_site anchor
_page b.html '<a href="a.html#nosuch">x</a> <a href="#here">y</a>'
out="$(t_out _gate "${SITE}")"
t_assert_contains "${out}" "anchor  a.html#nosuch"
t_assert_contains "${out}" "anchor  b.html#here" "a same-page anchor is checked too"
t_assert_fails _gate "${SITE}"

t_case "an anchor matches the id as written (rustdoc's impl ids) or decoded"
_site encoded
_page b.html '<a href="a.html#impl-From%3CT%3E-for-X">x</a>'
t_assert_eq 1 "$(t_out _gate "${SITE}" | grep -c 'anchor  ')" "only the id that exists in neither spelling fails"

t_case "a link that climbs out of the site root fails, even when the file exists outside it"
_site escape
printf '<html></html>\n' > "${_WORK}/escape/outside.html"
_page b.html '<a href="../outside.html">x</a>'
t_assert_contains "$(t_out _gate "${SITE}")" "missing  ../outside.html"
t_assert_fails _gate "${SITE}"

t_case "a link to a directory needs its index.html"
_site dir
mkdir -p "${SITE}/empty"
_page b.html '<a href="empty/">x</a>'
t_assert_contains "$(t_out _gate "${SITE}")" "missing  empty/"

t_case "an absolute path is served from the site root"
_site absolute
_page b.html '<a href="/nope.html">x</a>'
t_assert_contains "$(t_out _gate "${SITE}")" "missing  nope.html"
t_assert_eq 1 "$(t_out _gate "${SITE}" | grep -c 'missing  ')" "/a.html on the index resolves"

t_case "<base href> moves every relative link, as in a browser"
_site base
_page deep/b.html '<base href="../"><a href="a.html">x</a>'
t_assert_ok _gate "${SITE}"

t_case "a fragment dartdoc injects by script is not a document: its root-relative links are not misread"
_site fragment
mkdir -p "${SITE}/lib"
printf '<ol><li><a href="a.html">a</a></li></ol>\n' > "${SITE}/lib/lib-sidebar.html"
t_assert_ok _gate "${SITE}"

t_case "a meta refresh is a link"
_site refresh
_page b.html '<meta http-equiv="refresh" content="0; url=gone/index.html">'
t_assert_contains "$(t_out _gate "${SITE}")" "missing  gone/index.html"

t_case "a rustdoc line range needs both ends"
_site lines
_page b.html '<a href="src/lib.rs.html#2-9">x</a>'
t_assert_contains "$(t_out _gate "${SITE}")" "anchor  src/lib.rs.html#2-9"

t_case "a site without index.html at its root fails"
_site noindex
rm "${SITE}/index.html"
t_assert_contains "$(t_out _gate "${SITE}")" "missing  index.html"

t_case "the allow file freezes a known exception, and a resolved one is STALE"
_site allow
_page b.html '<a href="nope.html">x</a>'
printf '# known\nmissing\tnope.html\n' > "${_WORK}/allow/site-links.allow"
t_assert_ok _gate "${SITE}" --allow "${_WORK}/allow/site-links.allow"
printf 'missing\tnope.html\nanchor\ta.html#gone\n' > "${_WORK}/allow/stale.allow"
t_assert_fails _gate "${SITE}" --allow "${_WORK}/allow/stale.allow"
t_assert_contains "$(t_out _gate "${SITE}" --allow "${_WORK}/allow/stale.allow")" "STALE"

t_case "--print-keys prints the allow-file keys and passes"
t_assert_eq "$(printf 'missing\tnope.html')" "$(_gate "${SITE}" --print-keys)"
t_assert_ok _gate "${SITE}" --print-keys

t_case "a site directory or allow file that does not exist is a usage error"
t_assert_eq 2 "$(t_rc _gate "${_WORK}/no-such-site")"
t_assert_eq 2 "$(t_rc _gate "${SITE}" --allow "${_WORK}/no-such.allow")" "a typo'd allow path must not read as an empty freeze"

t_summary
