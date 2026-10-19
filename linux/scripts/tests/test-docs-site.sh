#!/usr/bin/env bash
# docs-site.sh plan, build and stage, and the publish contract of build-docs.yml. See docs/docs-sites.md#the-reusable-workflow
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
WORKFLOW="$(cd "${SCRIPTS}/../.." && pwd)/.github/workflows/build-docs.yml"
_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

# _plan [VAR=value...]: docs-site.sh plan with only the given inputs set.
_plan() {
  env -u DOCS_COMMAND -u DOCS_BUILDER -u DOCS_ARTIFACT -u DOCS_SITE_DIR -u DOCS_HUB "$@" \
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

# A copy of the hub's script beside stub drivers, so a builder's dispatch is visible without cargo, pip or dart.
FAKE="${_tmp}/hub"
mkdir -p "${FAKE}/linux/scripts/02-toolchain/rust" "${FAKE}/linux/scripts/02-toolchain/python" "${FAKE}/linux/scripts/lib"
cp "${SCRIPTS}/docs-site.sh" "${FAKE}/linux/scripts/"
printf 'echo rustdoc-driver\n' > "${FAKE}/linux/scripts/02-toolchain/rust/cargo_build_doc.sh"
printf 'echo python-driver\n' > "${FAKE}/linux/scripts/02-toolchain/python/ci_build_docs.sh"
printf 'dartdoc_build_main() { echo "dartdoc theme=${DARTDOC_BUILD_THEME_CSS} before=${DARTDOC_BUILD_CLEAN_CMD[*]} images=${DARTDOC_BUILD_IMAGES_DIR:-}"; }\n' \
  > "${FAKE}/linux/scripts/lib/dartdoc-build.sh"
mkdir -p "${_tmp}/dart-plain" "${_tmp}/dart-images/images"
_build() { env -u DOCS_COMMAND -u DOCS_BUILDER "$@" bash "${FAKE}/linux/scripts/docs-site.sh" build; }

t_case "build: a command runs at the working directory, a builder runs the hub's driver"
(cd "${_tmp}" && _build DOCS_COMMAND='echo built > built.txt')
t_assert_eq "built" "$(cat "${_tmp}/built.txt" 2>/dev/null)"
t_assert_eq "rustdoc-driver" "$(_build DOCS_BUILDER=rustdoc)"
t_assert_eq "python-driver" "$(_build DOCS_BUILDER=python)"
t_assert_eq "dartdoc theme=${FAKE}/third_party/DocumANTation/style/dartdoc.css before=flutter pub get images=" \
  "$(cd "${_tmp}/dart-plain" && _build DOCS_BUILDER=dartdoc)" \
  "the brand sheet from the hub's DocumANTation, and the packages resolved first"
t_assert_contains "$(cd "${_tmp}/dart-images" && _build DOCS_BUILDER=dartdoc)" "images=${_tmp}/dart-images/images" \
  "the README's images/logo.png is a dead link on the site unless images/ is copied (ANThology, 2026-10-19)"
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

t_case "stage: the hub's .htaccess and 404 page go in, then the link gate passes"
_site plain
t_assert_ok _stage "${SITE}"
t_assert_eq "" "$(diff "${SCRIPTS}/../webserver/templates/docs-site.htaccess" "${SITE}/.htaccess" 2>&1)"
t_assert_eq "" "$(diff "${SCRIPTS}/../webserver/templates/docs-site-404.html" "${SITE}/404.html" 2>&1)"

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

t_summary
