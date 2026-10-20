#!/usr/bin/env bash
# check-docs-sidebars.js (toggles, Exhale tree views, uncaught exceptions) and its three callers, against fixture sites in headless Chrome. See docs/docs-sites.md#the-sidebar-toggle-check
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
CHECK="${SCRIPTS}/check-docs-sidebars.js"
_tmp="$(mktemp -d)"
_server=""
trap '[ -z "${_server}" ] || kill "${_server}" 2>/dev/null; rm -rf "${_tmp}"' EXIT

t_skip_unless "node with a global WebSocket (22 and later)" node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)'
_chrome=""
for c in "${CHROME_EXECUTABLE:-}" chrome google-chrome chromium chromium-browser; do
  [ -n "${c}" ] && command -v "${c}" >/dev/null 2>&1 && { _chrome="${c}"; break; }
done
t_skip_unless "Chrome (CHROME_EXECUTABLE, chrome, google-chrome or chromium)" test -n "${_chrome}"
_chrome="$(command -v "${_chrome}")"
export CHECK_DOCS_SIDEBARS_VIEWPORTS="1000x700"

# _site <name> <theme marker> <style> <body> <script>: a one-page site the check takes for that theme; prints its dir.
_site() {
  local d="${_tmp}/$1"
  mkdir -p "$(dirname "${d}/$2")"
  : > "${d}/$2"
  printf '<!DOCTYPE html><html><head><style>body{margin:0} %s</style></head><body>%s<script>%s</script></body></html>
'     "$3" "$4" "$5" > "${d}/index.html"
  printf '%s
' "${d}"
}

# _sphinx <name> <variant>: a book-theme-shaped page whose one primary toggle behaves as <variant> says.
_sphinx() {
  local toggle='<button class="primary-toggle" style="left:250px">=</button>' extra='' js=''
  local on="document.querySelector('.primary-toggle').addEventListener('click', () =>"
  case "$2" in
    works) js="${on} sb.classList.toggle('gone'));" ;;
    dead) ;;
    hidden-twin) toggle="<button class=\"primary-toggle\" style=\"display:none\">=</button>${toggle}"; js="${on} sb.classList.toggle('gone'));" ;;
    off-screen) toggle='<button class="primary-toggle" style="left:-120px">=</button>'; js="${on} sb.classList.toggle('gone'));" ;;
    covered) extra='<div style="position:fixed;left:240px;top:0;width:60px;height:60px;z-index:9"></div>'; js="${on} sb.classList.toggle('gone'));" ;;
    one-way) js="${on} sb.classList.add('gone'));" ;;
    dialog) extra='<dialog id="pst-primary-sidebar-modal">nav</dialog><style>#pst-primary-sidebar{display:none}</style>'
      js="${on} document.getElementById('pst-primary-sidebar-modal').showModal());" ;;
    no-toggle) toggle=''; extra='<style>#pst-primary-sidebar{display:none}</style>' ;;
    throws) js="${on} sb.classList.toggle('gone')); setTimeout(() => { throw new TypeError('boom'); });" ;;
    rejects) js="${on} sb.classList.toggle('gone')); Promise.reject(new Error('nope'));" ;;
  esac
  _site "$1" _static/scripts/sphinx-book-theme.js     '.primary-toggle{position:fixed;top:5px;width:30px;height:30px} #pst-primary-sidebar{position:fixed;left:0;top:50px;width:200px;height:300px;background:#cfc} #pst-primary-sidebar.gone{display:none}'     "${toggle}<div id=\"pst-primary-sidebar\">nav</div>${extra}"     "const sb = document.getElementById('pst-primary-sidebar'); ${js}"
}

# _dartdoc <name> <closes|stays>: dartdoc's drawer at 840 px and below, which the overlay under it closes or not.
_dartdoc() {
  local close="ov.addEventListener('click', () => { sb.classList.remove('active'); ov.classList.remove('active'); });"
  [ "$2" = closes ] || close=''
  _site "$1" static-assets/docs.dart.js     '#sidenav-left-toggle{position:fixed;left:10px;top:5px;width:30px;height:30px} #dartdoc-sidebar-left{position:fixed;left:-400px;top:0;width:300px;height:500px;background:#cfc;z-index:2000} #dartdoc-sidebar-left.active{left:0} #overlay-under-drawer{display:none} #overlay-under-drawer.active{display:block;position:fixed;inset:0;z-index:1999;background:#0006}'     '<span id="sidenav-left-toggle" role="button">=</span><div id="dartdoc-sidebar-left">nav</div><div id="overlay-under-drawer"></div>'     "const sb = document.getElementById('dartdoc-sidebar-left'), ov = document.getElementById('overlay-under-drawer'); document.getElementById('sidenav-left-toggle').addEventListener('click', () => { sb.classList.add('active'); ov.classList.add('active'); }); ${close}"
}

# _tree <name> <variant>: a Sphinx site whose api/library_root.html holds an Exhale-shaped tree view that folds as <variant> says.
_tree() {
  local d bind="" call="apply();"
  d="$(_site "$1" _static/scripts/sphinx-book-theme.js '' '<p>home</p>' '')"
  local unfold="li.addEventListener('click', (e) => { if (e.target.closest('li') === li) fold(li); });"
  case "$2" in
    folds) bind="${unfold}" ;;
    stuck) ;;
    one-way) bind="li.addEventListener('click', () => { li.querySelector(':scope > ul').style.display = 'block'; li.className = 'collapsibleListOpen'; });" ;;
    jquery) bind="${unfold}"; call='$(document).ready(apply);' ;;
  esac
  mkdir -p "${d}/api"
  # Taller than the viewport once open, as BeschleunigerBallett's first namespace is.
  printf '<!DOCTYPE html><html><body><ul class="treeView"><li><ul class="collapsibleList"><li>Namespace <a href="../index.html">ns</a><ul>%s</ul></li></ul></li></ul><script>%s</script></body></html>\n' \
    "$(for n in $(seq 80); do printf '<li>Class <a href="../index.html">Foo%s</a></li>' "${n}"; done)" \
    "const fold = (li) => { const ul = li.querySelector(':scope > ul'); const open = ul.style.display === 'none'; ul.style.display = open ? 'block' : 'none'; li.className = open ? 'collapsibleListOpen' : 'collapsibleListClosed'; }; const apply = () => document.querySelectorAll('ul.collapsibleList li').forEach((li) => { if (!li.querySelector(':scope > ul')) return; fold(li); ${bind} }); ${call}" \
    > "${d}/api/library_root.html"
  printf '%s\n' "${d}"
}

t_case "a toggle that opens and closes its sidebar passes"
out="$(t_out node "${CHECK}" "$(_sphinx works works)")"
t_assert_contains "${out}" "ok   1000x700 primary: open -> closed -> open"
t_assert_contains "${out}" "ok   1000x700 secondary: no such sidebar on this page"
t_assert_rc 0 node "${CHECK}" "${_tmp}/works"

t_case "a toggle that does nothing fails"
t_assert_rc 1 node "${CHECK}" "$(_sphinx dead dead)"
t_assert_contains "$(t_out node "${CHECK}" "${_tmp}/dead")" "FAIL 1000x700 primary: clicking the toggle at "
t_assert_contains "$(t_out node "${CHECK}" "${_tmp}/dead")" " leaves it open"

t_case "a hidden twin first in the DOM takes the theme JS, so the visible toggle is dead (pydata 0.20's header)"
t_assert_contains "$(t_out node "${CHECK}" "$(_sphinx twin hidden-twin)")" "leaves it open"

t_case "a toggle off-screen or under another element fails before it is clicked"
t_assert_contains "$(t_out node "${CHECK}" "$(_sphinx off off-screen)")" " is off-screen"
t_assert_contains "$(t_out node "${CHECK}" "$(_sphinx cov covered)")" " is covered by another element"

t_case "a toggle that opens but cannot close again fails"
t_assert_contains "$(t_out node "${CHECK}" "$(_sphinx oneway one-way)")" "FAIL 1000x700 primary: open -> closed, and it does not go back"

t_case "a dialog the toggle opens is closed with Escape"
t_assert_contains "$(t_out node "${CHECK}" "$(_sphinx dlg dialog)")" "ok   1000x700 primary: closed -> open -> closed"

t_case "a hidden sidebar without a toggle fails"
t_assert_contains "$(t_out node "${CHECK}" "$(_sphinx none no-toggle)")" "FAIL 1000x700 primary: hidden, and no toggle opens it"

t_case "dartdoc's drawer opens with its toggle and closes on the overlay"
t_assert_contains "$(t_out node "${CHECK}" "$(_dartdoc drawer closes)")" "ok   1000x700 left: closed -> open -> closed"
t_assert_contains "$(t_out node "${CHECK}" "$(_dartdoc stuck stays)")" "FAIL 1000x700 left: closed -> open, and it does not go back"

t_case "an uncaught exception or rejection fails the page, even where every toggle works"
out="$(t_out node "${CHECK}" "$(_sphinx throws throws)")"
t_assert_contains "${out}" "ok   1000x700 primary: open -> closed -> open"
t_assert_contains "${out}" "FAIL 1000x700: uncaught TypeError: boom (http://127.0.0.1:"
t_assert_rc 1 node "${CHECK}" "${_tmp}/throws"
t_assert_contains "$(t_out node "${CHECK}" "$(_sphinx rejects rejects)")" "FAIL 1000x700: uncaught (in promise) Error: nope"

t_case "a tree view that folds and unfolds passes, on a page found without being named"
out="$(t_out node "${CHECK}" "$(_tree folds folds)")"
t_assert_contains "${out}" "  api/library_root.html"
t_assert_contains "${out}" "ok   1000x700 tree: closed -> open -> closed (item at "
t_assert_rc 0 node "${CHECK}" "${_tmp}/folds"

t_case "Exhale's jQuery applier with no jQuery (Sphinx 6 and later): uncaught ReferenceError, and nothing folds"
out="$(t_out node "${CHECK}" "$(_tree jq jquery)")"
t_assert_contains "${out}" "FAIL 1000x700: uncaught ReferenceError: \$ is not defined"
t_assert_contains "${out}" "FAIL 1000x700 tree: no item folds; the tree view's script did not run"
t_assert_rc 1 node "${CHECK}" "${_tmp}/jq"

t_case "a tree item that does not fold, or does not unfold again, fails"
t_assert_contains "$(t_out node "${CHECK}" "$(_tree stuck stuck)")" "FAIL 1000x700 tree: clicking the item at "
t_assert_contains "$(t_out node "${CHECK}" "${_tmp}/stuck")" " leaves it closed"
t_assert_contains "$(t_out node "${CHECK}" "$(_tree oneway-tree one-way)")" "FAIL 1000x700 tree: closed -> open, and it does not go back"

t_case "a published site checks the pages named after its URL; a page outside the site or not built is a usage error"
"${PYTHON:-python3}" -c 'import functools, http.server, sys; s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])); open(sys.argv[2], "w").write(str(s.server_port)); s.serve_forever()' \
  "$(_tree served folds)" "${_tmp}/port" >/dev/null 2>&1 &
_server=$!
for _ in $(seq 100); do [ -s "${_tmp}/port" ] && break; sleep 0.1; done
t_assert_contains "$(t_out node "${CHECK}" "http://127.0.0.1:$(cat "${_tmp}/port")" api/library_root.html)" "ok   1000x700 tree: closed -> open -> closed"
t_assert_rc 2 node "${CHECK}" "${_tmp}/folds" api/no-such-page.html
t_assert_rc 2 node "${CHECK}" "${_tmp}/folds" ../folds/index.html

t_case "a site of neither theme has nothing to toggle; a missing site or argument is a usage error"
mkdir -p "${_tmp}/plain" && printf '<!DOCTYPE html><html><body>hi</body></html>\n' > "${_tmp}/plain/index.html"
t_assert_contains "$(t_out node "${CHECK}" "${_tmp}/plain")" "nothing to toggle"
t_assert_rc 0 node "${CHECK}" "${_tmp}/plain"
t_assert_rc 2 node "${CHECK}" "${_tmp}/no-such-site"
t_assert_rc 2 node "${CHECK}"

t_case "docs-site.sh check runs the click check; --if-chrome skips only without CHROME_EXECUTABLE"
t_assert_rc 0 bash "${SCRIPTS}/docs-site.sh" check "${_tmp}/works"
t_assert_rc 1 bash "${SCRIPTS}/docs-site.sh" check "${_tmp}/dead"
t_assert_contains "$(CHROME_EXECUTABLE='' t_out bash "${SCRIPTS}/docs-site.sh" check "${_tmp}/dead" --if-chrome)" "sidebar check skipped"
t_assert_rc 1 env CHROME_EXECUTABLE="${_chrome}" bash "${SCRIPTS}/docs-site.sh" check "${_tmp}/dead" --if-chrome
t_assert_rc 1 bash "${SCRIPTS}/docs-site.sh" check "${_tmp}/works" --bogus

t_case "build-docs.yml builds and clicks in one container command, since its script is docker run's argv"
t_assert_grep "${SCRIPTS}/../../.github/workflows/build-docs.yml" '^          script: bash \$\{\{ steps\.plan\.outputs\.hub \}\}/linux/scripts/docs-site\.sh build \$\{\{ steps\.plan\.outputs\.site-dir \}\}$'
t_assert_rc 0 env -u DOCS_BUILDER DOCS_COMMAND=true bash "${SCRIPTS}/docs-site.sh" build "${_tmp}/works"
t_assert_rc 1 env -u DOCS_BUILDER DOCS_COMMAND=true bash "${SCRIPTS}/docs-site.sh" build "${_tmp}/dead"
t_assert_rc 0 env -u DOCS_BUILDER DOCS_COMMAND=true bash "${SCRIPTS}/docs-site.sh" build

t_case "docs-build.sh clicks the toggles after make html, where an artifact site is built"
mkdir -p "${_tmp}/proj/docs" "${_tmp}/bin"
cat > "${_tmp}/bin/make" <<EOF
#!/usr/bin/env bash
mkdir -p build && rm -rf build/html && cp -r "${_tmp}/\${FIXTURE}" build/html
EOF
chmod +x "${_tmp}/bin/make"
_docs_build() {
  (export PATH="${_tmp}/bin:${PATH}" CHROME_EXECUTABLE="${_chrome}" FIXTURE="$1" DOCS_BUILD_PROJECT_ROOT="${_tmp}/proj" DOCS_BUILD_TARGETS=html
   source "${SCRIPTS}/lib/docs-build.sh"
   docs_build_sphinx)
}
t_assert_rc 0 _docs_build works
t_assert_rc 1 _docs_build dead

t_case "ci_build_docs.sh clicks the toggles after make html"
t_assert_grep "${SCRIPTS}/02-toolchain/python/ci_build_docs.sh" '^bash "\$SCRIPT_DIR/\.\./\.\./docs-site\.sh" check "\$WORKSPACE_ROOT/docs/build/html" --if-chrome$'

t_summary
