#!/usr/bin/env bash
# docs-site.sh plan, build, stage and live, and the publish contract of build-docs.yml. See docs/docs-sites.md#the-reusable-workflow
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
WORKFLOW="$(cd "${SCRIPTS}/../.." && pwd)/.github/workflows/build-docs.yml"
_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

# _plan [VAR=value...]: docs-site.sh plan with only the given inputs set.
_plan() {
  env -u DOCS_COMMAND -u DOCS_BUILDER -u DOCS_ARTIFACT -u DOCS_SITE_DIR -u DOCS_HUB -u DOCS_GUIDES "$@" \
    bash "${SCRIPTS}/docs-site.sh" plan
}

t_case "plan: a command builds into the site-dir it names"
t_assert_eq "$(printf 'site-dir=docs/_build/html\nhub=.')" "$(_plan DOCS_COMMAND='bash build.sh' DOCS_SITE_DIR=docs/_build/html)"
t_assert_eq "site-dir=docs/build/html" "$(_plan DOCS_COMMAND=x DOCS_SITE_DIR=docs/build/html/ | head -n 1)" "one trailing slash is dropped"
t_assert_fails _plan DOCS_COMMAND='bash build.sh'

t_case "plan: a builder knows where its driver writes"
t_assert_eq "site-dir=target/doc" "$(_plan DOCS_BUILDER=rustdoc | head -n 1)"
t_assert_eq "site-dir=docs/build/html" "$(_plan DOCS_BUILDER=python | head -n 1)"
t_assert_eq "site-dir=doc/api" "$(_plan DOCS_BUILDER=dartdoc | head -n 1)"
t_assert_eq "site-dir=out/doc" "$(_plan DOCS_BUILDER=rustdoc DOCS_SITE_DIR=out/doc | head -n 1)" "a given site-dir wins"
t_assert_fails _plan DOCS_BUILDER=sphinx-maybe

t_case "plan: an artifact is the site, downloaded into .docs-site"
t_assert_eq "site-dir=.docs-site" "$(_plan DOCS_ARTIFACT=python-docs-site | head -n 1)"
t_assert_fails _plan DOCS_ARTIFACT=python-docs-site DOCS_SITE_DIR=docs

t_case "plan: exactly one of command, builder and artifact"
t_assert_fails _plan
t_assert_fails _plan DOCS_COMMAND=x DOCS_BUILDER=rustdoc DOCS_SITE_DIR=docs
t_assert_contains "$(t_out _plan DOCS_BUILDER=rustdoc DOCS_ARTIFACT=a)" "set exactly one of command, builder and artifact; 2 are set"

t_case "plan: paths stay inside the checkout and hold nothing a shell would read"
for bad in ../site /abs/site 'docs build' 'docs;rm' "docs\$(id)"; do
  t_assert_fails _plan DOCS_COMMAND=x DOCS_SITE_DIR="${bad}"
done
t_assert_eq "hub=antfrastructure-tools" "$(_plan DOCS_BUILDER=rustdoc DOCS_HUB=antfrastructure-tools | tail -n 1)"
t_assert_fails _plan DOCS_BUILDER=rustdoc DOCS_HUB='tools && id'

t_case "plan: guides are the dartdoc and rustdoc builders', one <source>|<slug>|<nav title> per line"
t_assert_eq "site-dir=doc/api" "$(_plan DOCS_BUILDER=dartdoc DOCS_GUIDES="$(printf '  guides/a.md|a|A guide\n\nguides/b.md|b-2|B, the second\n')" | head -n 1)"
t_assert_eq "site-dir=target/doc" "$(_plan DOCS_BUILDER=rustdoc DOCS_GUIDES='guides/a.md|a|A guide' | head -n 1)"
t_assert_contains "$(t_out _plan DOCS_COMMAND=x DOCS_SITE_DIR=doc/api DOCS_GUIDES='guides/a.md|a|A')" "guides is the dartdoc and rustdoc builders' guide list"
t_assert_fails _plan DOCS_BUILDER=python DOCS_GUIDES='guides/a.md|a|A'
for bad in 'guides/a.md|a' 'guides/a.md||A' '../a.md|a|A' '/a.md|a|A' 'guides/a.md|a/b|A' 'guides/a.md|a b|A'; do
  t_assert_fails _plan DOCS_BUILDER=dartdoc DOCS_GUIDES="${bad}"
  t_assert_fails _plan DOCS_BUILDER=rustdoc DOCS_GUIDES="${bad}"
done

# A copy of the hub's script beside stub drivers, so a builder's dispatch is visible without cargo, pip or dart.
FAKE="${_tmp}/hub"
mkdir -p "${FAKE}/linux/scripts/02-toolchain/rust" "${FAKE}/linux/scripts/02-toolchain/python" "${FAKE}/linux/scripts/lib"
cp "${SCRIPTS}/docs-site.sh" "${FAKE}/linux/scripts/"
printf 'echo rustdoc-driver\n' > "${FAKE}/linux/scripts/02-toolchain/rust/cargo_build_doc.sh"
printf 'echo python-driver\n' > "${FAKE}/linux/scripts/02-toolchain/python/ci_build_docs.sh"
printf 'dartdoc_build_main() { echo "dartdoc theme=${DARTDOC_BUILD_THEME_CSS} before=${DARTDOC_BUILD_CLEAN_CMD[*]} images=${DARTDOC_BUILD_IMAGES_DIR:-} guides=${DARTDOC_BUILD_GUIDES[*]:-}"; }\n' \
  > "${FAKE}/linux/scripts/lib/dartdoc-build.sh"
printf 'dartdoc_build_stage_guides() { echo staged; }\ndartdoc_build_prepare_python_env() { :; }\ndartdoc_build_render_guides() { echo "rendered api=${DARTDOC_BUILD_API_DIR} flavor=${DARTDOC_BUILD_FLAVOR} shell=${DARTDOC_BUILD_SHELL} guides=${DARTDOC_BUILD_GUIDES[*]}"; }\n' \
  >> "${FAKE}/linux/scripts/lib/dartdoc-build.sh"
mkdir -p "${_tmp}/dart-plain" "${_tmp}/dart-images/images" "${_tmp}/rust-crate"
printf '[package]\nname = "my-crate"\nversion = "0.1.0"\n' > "${_tmp}/rust-crate/Cargo.toml"
_build() { env -u DOCS_COMMAND -u DOCS_BUILDER -u DOCS_GUIDES "$@" bash "${FAKE}/linux/scripts/docs-site.sh" build; }

t_case "build: a command runs at the working directory, a builder runs the hub's driver"
(cd "${_tmp}" && _build DOCS_COMMAND='echo built > built.txt')
t_assert_eq "built" "$(cat "${_tmp}/built.txt" 2>/dev/null)"
t_assert_eq "rustdoc-driver" "$(_build DOCS_BUILDER=rustdoc)"
t_assert_eq "python-driver" "$(_build DOCS_BUILDER=python)"
t_assert_eq "dartdoc theme=${FAKE}/third_party/DocumANTation/style/dartdoc.css before=flutter pub get images= guides=" \
  "$(cd "${_tmp}/dart-plain" && _build DOCS_BUILDER=dartdoc)" \
  "the brand sheet from the hub's DocumANTation, and the packages resolved first"
t_assert_contains "$(cd "${_tmp}/dart-images" && _build DOCS_BUILDER=dartdoc)" "images=${_tmp}/dart-images/images" \
  "the README's images/logo.png is a dead link on the site unless images/ is copied (ANThology, 2026-10-19)"
t_assert_contains "$(cd "${_tmp}/dart-plain" && _build DOCS_BUILDER=dartdoc DOCS_GUIDES="$(printf 'guides/a.md|a|A guide\nguides/b.md|b|B')")" \
  "guides=${_tmp}/dart-plain/guides/a.md|a|A guide ${_tmp}/dart-plain/guides/b.md|b|B" "each guide, its source from the repository root"

t_case "build: rustdoc's guides go beside the root package's crate page, after the driver"
t_assert_eq "$(printf 'rustdoc-driver\nstaged\nrendered api=%s/rust-crate/target/doc flavor=rustdoc shell=my_crate/index.html guides=%s/rust-crate/guides/a.md|a|A' "${_tmp}" "${_tmp}")" \
  "$(cd "${_tmp}/rust-crate" && _build DOCS_BUILDER=rustdoc DOCS_GUIDES='guides/a.md|a|A')" "cargo doc names the directory my_crate"
t_assert_eq "rustdoc-driver" "$(cd "${_tmp}/rust-crate" && _build DOCS_BUILDER=rustdoc)" "no guides, no renderer"
mkdir -p "${_tmp}/dart-plain/doc/api/static-assets"
: > "${_tmp}/dart-plain/doc/api/.htaccess"
(cd "${_tmp}/dart-plain" && _build DOCS_BUILDER=dartdoc >/dev/null)
t_assert_eq 0 "$([ -e "${_tmp}/dart-plain/doc/api" ] && echo 1 || echo 0)" \
  "dart doc writes over doc/api, so the last build's staged .htaccess would fail stage"
t_assert_fails _build DOCS_BUILDER=nope
t_assert_fails _build DOCS_COMMAND='exit 3'

# _site <name>: a built site whose links resolve.
_site() {
  SITE="${_tmp}/$1"
  mkdir -p "${SITE}"
  printf '<!DOCTYPE html>\n<html><body><a href="page.html">p</a></body></html>\n' > "${SITE}/index.html"
  printf '<!DOCTYPE html>\n<html><body><a href="index.html">i</a></body></html>\n' > "${SITE}/page.html"
}
_stage() { PYTHON="${PREFLIGHT_PYTHON:-python3}" bash "${SCRIPTS}/docs-site.sh" stage "$@"; }
# _staged <template> <file>: the diff between a hub template and what stage put in the site; empty when they match.
_staged() { diff "${SCRIPTS}/../webserver/templates/$1" "$2" 2>&1; }

t_case "stage: the hub's .htaccess and 404 page go in, then the link gate passes"
_site plain
t_assert_ok _stage "${SITE}"
t_assert_eq "" "$(_staged docs-site.htaccess "${SITE}/.htaccess")"
t_assert_eq "" "$(_staged docs-site-404.html "${SITE}/404.html")"

t_case "stage: a site's own 404 page is kept"
_site own404
printf '<!DOCTYPE html>\n<html><body>own</body></html>\n' > "${SITE}/404.html"
t_assert_ok _stage "${SITE}"
t_assert_contains "$(cat "${SITE}/404.html")" "own"

t_case "stage: a site that ships a .htaccess is refused, unless it opts out"
_site ownhtaccess
printf 'Options -Indexes\n' > "${SITE}/.htaccess"
t_assert_fails _stage "${SITE}"
t_assert_eq "Options -Indexes" "$(cat "${SITE}/.htaccess")" "refused, not overwritten"
t_assert_ok _stage "${SITE}" --no-htaccess
t_assert_eq 0 "$([ -e "${SITE}/404.html" ] && echo 1 || echo 0)" "no 404 page without the .htaccess that names it"

t_case "stage: a dead link fails, unless the allow file freezes it"
_site dead
printf '<!DOCTYPE html>\n<html><body><a href="gone.html">g</a></body></html>\n' > "${SITE}/page.html"
t_assert_fails _stage "${SITE}"
printf 'missing\tgone.html\n' > "${_tmp}/dead.allow"
t_assert_ok _stage "${SITE}" --allow "${_tmp}/dead.allow" --no-htaccess
t_assert_fails _stage "${_tmp}/no-such-site"

t_case "stage: an isolated app gets the isolated-app .htaccess in its own directory, the root keeps its own"
_site isolated
app="${SITE}/app"
mkdir -p "${app}"
printf '<!DOCTYPE html>\n<html><head><base href="/app/"></head><body><a href="main.dart.js">m</a></body></html>\n' > "${app}/index.html"
printf 'x' > "${app}/main.dart.js"
t_assert_ok _stage "${SITE}" --isolated-app app/
t_assert_eq "" "$(_staged flutter-web-isolated.htaccess "${app}/.htaccess")" "the app's directory gets the isolated template"
t_assert_eq "" "$(_staged docs-site.htaccess "${SITE}/.htaccess")" "the root keeps the docs site's"

t_case "stage: an isolated app that is missing, ships its own .htaccess or climbs out of the site is refused"
_site isolated-missing
t_assert_fails _stage "${SITE}" --isolated-app app
t_assert_contains "$(t_out _stage "${SITE}" --isolated-app app --no-htaccess)" "has no index.html"
_site isolated-own
mkdir -p "${SITE}/app"
printf '<!DOCTYPE html>\n<html><body>app</body></html>\n' > "${SITE}/app/index.html"
printf 'Header set X-Own 1\n' > "${SITE}/app/.htaccess"
t_assert_fails _stage "${SITE}" --isolated-app app
t_assert_eq "Header set X-Own 1" "$(cat "${SITE}/app/.htaccess")" "refused, not overwritten"
_site isolated-climb
t_assert_contains "$(t_out _stage "${SITE}" --isolated-app ../isolated --no-htaccess)" "must be a plain path inside the repository"

# A node on PATH that prints its arguments and fails for a URL with "broken" in it, so live's calls are visible without Chrome.
mkdir -p "${_tmp}/fake-bin" "${_tmp}/live/app" "${_tmp}/live/demo"
printf '#!/usr/bin/env bash\necho "node $*"\ncase "$2" in *broken*) exit 1 ;; esac\n' > "${_tmp}/fake-bin/node"
chmod +x "${_tmp}/fake-bin/node"
_live() { (cd "${_tmp}" && env -u DOCS_LIVE_URL -u DOCS_ISOLATED_APPS PATH="${_tmp}/fake-bin:${PATH}" "$@" bash "${FAKE}/linux/scripts/docs-site.sh" live live); }
_checked() { printf 'node %s/linux/scripts/check-live-site.js https://docs.example.org/%s/ --files live/%s --isolated' "${FAKE}" "$1" "$1"; }

t_case "live: each isolated app at its published URL, against the files published, isolated"
t_assert_eq "$(_checked app; printf '\n'; _checked demo)" "$(_live DOCS_LIVE_URL=https://docs.example.org/ DOCS_ISOLATED_APPS='app demo/')"
t_assert_eq "$(_checked app)" "$(_live DOCS_LIVE_URL=https://docs.example.org DOCS_ISOLATED_APPS=app)" "with or without the URL's trailing slash"

t_case "live: an app published with models/manifest.json is checked by its models' bytes too"
mkdir -p "${_tmp}/live/models-app/models"
printf '{}' > "${_tmp}/live/models-app/models/manifest.json"
t_assert_eq "node ${FAKE}/linux/scripts/check-live-site.js https://docs.example.org/models-app/ --models live/models-app/models/manifest.json --files live/models-app --isolated" \
  "$(_live DOCS_LIVE_URL=https://docs.example.org/ DOCS_ISOLATED_APPS=models-app)"

t_case "live: a red app fails the job, and the apps after it are still checked"
mkdir -p "${_tmp}/live/broken"
t_assert_fails _live DOCS_LIVE_URL=https://docs.example.org/ DOCS_ISOLATED_APPS='broken app'
t_assert_contains "$(t_out _live DOCS_LIVE_URL=https://docs.example.org/ DOCS_ISOLATED_APPS='broken app')" "$(_checked app)"

t_case "live: an https URL, at least one app, every app inside the site"
t_assert_fails _live DOCS_LIVE_URL=http://docs.example.org/ DOCS_ISOLATED_APPS=app
t_assert_contains "$(t_out _live DOCS_ISOLATED_APPS=app)" "live-url is the published site's https:// address"
t_assert_contains "$(t_out _live DOCS_LIVE_URL=https://docs.example.org/)" "none is named"
t_assert_fails _live DOCS_LIVE_URL=https://docs.example.org/ DOCS_ISOLATED_APPS=../app
t_assert_fails _live DOCS_LIVE_URL=https://docs.example.org/ DOCS_ISOLATED_APPS='app;id'

# _job <name>: the lines of one job of build-docs.yml, from its key to the next job's.
_job() { awk -v job="  $1:" '$0 == job { on = 1; next } on && /^  [a-z-]+:$/ { exit } on' "${WORKFLOW}"; }

t_case "build-docs.yml: publish on a push to develop or main only, never cancelled, never tolerated"
publish="$(_job publish)"
t_assert_contains "${publish}" "github.event_name == 'push'"
t_assert_contains "${publish}" "github.ref == 'refs/heads/develop' || github.ref == 'refs/heads/main'"
t_assert_contains "${publish}" "github.event_name == 'workflow_dispatch' && inputs.publish-on-dispatch"
t_assert_eq 0 "$(printf '%s\n' "${publish}" | grep -c 'pull_request')" "a pull request never publishes"
t_assert_contains "${publish}" "group: docs-publish-\${{ inputs.site-name }}"
t_assert_contains "${publish}" "cancel-in-progress: false"
t_assert_contains "${publish}" "uses: Kataglyphis/ANTfrastructure/.github/actions/deploy-over-ftp@develop"
t_assert_eq 0 "$(grep -c 'continue-on-error' "${WORKFLOW}")" "a publish that may fail is a site that stops updating unseen"
t_assert_contains "$(_job site)" "include-hidden-files: true"

t_case "build-docs.yml: the guides reach plan and the build container as an environment name"
t_assert_contains "$(_job site)" 'DOCS_GUIDES: ${{ inputs.guides }}'
t_assert_contains "$(_job site)" "extra-args: -e DOCS_COMMAND -e DOCS_BUILDER -e DOCS_GUIDES "

t_case "build-docs.yml: isolated-apps reaches the stager as an environment name, one --isolated-app per path"
# shellcheck disable=SC2016
t_assert_contains "$(_job site)" 'DOCS_ISOLATED_APPS: ${{ inputs.isolated-apps }}'
# shellcheck disable=SC2016
t_assert_contains "$(_job site)" 'args+=(--isolated-app "${app}")'

t_case "build-docs.yml: clean hosted disks before pulling the family image"
site="$(_job site)"
prepare="$(printf '%s\n' "$site" | awk '/- name: Prepare CI host / { inside=1; next } inside && /^      - name:/ { exit } inside')"
t_assert_contains "$prepare" "free-disk-space: 'true'"
t_assert_contains "$prepare" "pull-first: 'false'"
# shellcheck disable=SC2016
t_assert_contains "$prepare" 'submodules: ${{ inputs.submodules }}'

t_case "build-docs.yml: the live check runs after the publish, only when a live-url and isolated apps are given"
live_job="$(_job live-check)"
t_assert_contains "${live_job}" "    needs: publish"
t_assert_contains "${live_job}" "if: inputs.live-url != '' && inputs.isolated-apps != ''"
# shellcheck disable=SC2016
t_assert_contains "${live_job}" 'name: docs-site-${{ inputs.site-name }}'
t_assert_contains "${live_job}" "extra-args: -e DOCS_LIVE_URL -e DOCS_ISOLATED_APPS"
# shellcheck disable=SC2016
t_assert_contains "${live_job}" 'script: bash "${DOCS_HUB}/linux/scripts/docs-site.sh" live .docs-live'
t_assert_contains "${live_job}" "path: .docs-live"

t_summary
