#!/usr/bin/env bash
# docs-site.sh plan|build|check|stage: the steps of build-docs.yml, one place to test them. See docs/docs-sites.md#the-reusable-workflow
set -euo pipefail

DOCS_SITE_HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() { printf '::error title=docs-site: %s::%s\n' "$1" "$2" >&2; exit 1; }

# _docs_site_default_dir <builder>: where that hub driver writes its site.
_docs_site_default_dir() {
  case "$1" in
    rustdoc) printf 'target/doc\n' ;;
    python) printf 'docs/build/html\n' ;;
    dartdoc) printf 'doc/api\n' ;;
    *) die "unknown builder" "builder must be rustdoc, python or dartdoc, got '$1'." ;;
  esac
}

# _docs_site_relative <name> <path>: a path inside the checkout, one line, no '..', nothing a shell would read.
_docs_site_relative() {
  case "$2" in
    /* | *..* | *[!A-Za-z0-9._/-]*) die "bad $1" "$1 must be a plain path inside the repository, got '$2'." ;;
  esac
}

# _docs_site_guides: DOCS_GUIDES, one <source>|<slug>|<nav title> per line, into DOCS_SITE_GUIDES with absolute sources.
_docs_site_guides() {
  local line src slug title
  DOCS_SITE_GUIDES=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "${line}" ] || continue
    IFS='|' read -r src slug title <<<"${line}"
    [ -n "${src}" ] && [ -n "${slug}" ] && [ -n "${title}" ] || die "bad guide" "a guide is '<source>|<slug>|<nav title>', got '${line}'."
    _docs_site_relative "guide source" "${src}"
    case "${slug}" in
      *[!A-Za-z0-9_-]*) die "bad guide slug" "a slug names guide-<slug>.html, so letters, digits, - and _ only; got '${slug}'." ;;
    esac
    DOCS_SITE_GUIDES+=("$(pwd)/${src}|${slug}|${title}")
  done <<<"${DOCS_GUIDES:-}"
}

# plan: DOCS_COMMAND, DOCS_BUILDER, DOCS_ARTIFACT, DOCS_SITE_DIR, DOCS_GUIDES and DOCS_HUB in; site-dir= and hub= lines out.
docs_site_plan() {
  local modes=0 site="${DOCS_SITE_DIR:-}"
  [ -z "${DOCS_COMMAND:-}" ] || modes=$((modes + 1))
  [ -z "${DOCS_BUILDER:-}" ] || modes=$((modes + 1))
  [ -z "${DOCS_ARTIFACT:-}" ] || modes=$((modes + 1))
  [ "${modes}" -eq 1 ] || die "one source" "set exactly one of command, builder and artifact; ${modes} are set."
  if [ -n "${DOCS_GUIDES:-}" ]; then
    [ "${DOCS_BUILDER:-}" = dartdoc ] || die "guides without dartdoc" "guides is the dartdoc builder's guide list; a command sets its own."
    _docs_site_guides
  fi
  if [ -n "${DOCS_ARTIFACT:-}" ]; then
    [ -z "${site}" ] || die "site-dir with artifact" "the artifact's root is the site; leave site-dir empty."
    site=.docs-site
  elif [ -n "${DOCS_BUILDER:-}" ]; then
    _docs_site_default_dir "${DOCS_BUILDER}" >/dev/null
    site="${site:-$(_docs_site_default_dir "${DOCS_BUILDER}")}"
  fi
  [ -n "${site}" ] || die "no site-dir" "a command needs site-dir: the directory it builds the site into."
  _docs_site_relative site-dir "${site}"
  _docs_site_relative hub-path "${DOCS_HUB:-.}"
  printf 'site-dir=%s\nhub=%s\n' "${site%/}" "${DOCS_HUB:-.}"
}

# _docs_site_dartdoc: dartdoc_build_main with the hub's theme and the DOCS_GUIDES guide list.
_docs_site_dartdoc() {
  # shellcheck source=lib/dartdoc-build.sh
  source "${DOCS_SITE_HUB}/linux/scripts/lib/dartdoc-build.sh"
  # dart doc writes over doc/api, so a rebuild would keep the staged .htaccess, which stage then refuses.
  rm -rf doc/api
  _docs_site_guides
  # shellcheck disable=SC2034 # read by dartdoc_build_stage_guides and dartdoc_build_render_guides
  DARTDOC_BUILD_GUIDES=(${DOCS_SITE_GUIDES[@]+"${DOCS_SITE_GUIDES[@]}"})
  DARTDOC_BUILD_THEME_CSS="${DOCS_SITE_HUB}/third_party/DocumANTation/style/dartdoc.css"
  export DARTDOC_BUILD_THEME_CSS
  # shellcheck disable=SC2034 # read by dartdoc_build_generate
  DARTDOC_BUILD_CLEAN_CMD=(flutter pub get)
  # The README dart doc renders as index.html links images/ as the repository does.
  if [ -d images ]; then
    DARTDOC_BUILD_IMAGES_DIR="$(pwd)/images"
    export DARTDOC_BUILD_IMAGES_DIR
  fi
  dartdoc_build_main
}

# build [<site>]: inside the image, at the repository root; the command or the hub driver the builder names, then check <site>.
docs_site_build() {
  case "${DOCS_BUILDER:-}" in
    '') bash -lc "${DOCS_COMMAND:?no command and no builder}" ;;
    rustdoc) bash "${DOCS_SITE_HUB}/linux/scripts/02-toolchain/rust/cargo_build_doc.sh" ;;
    python) bash "${DOCS_SITE_HUB}/linux/scripts/02-toolchain/python/ci_build_docs.sh" ;;
    dartdoc) _docs_site_dartdoc ;;
    *) die "unknown builder" "builder must be rustdoc, python or dartdoc, got '${DOCS_BUILDER}'." ;;
  esac
  [ -n "${1:-}" ] || return 0
  docs_site_check "$1"
}

# stage <site> [--allow FILE] [--no-htaccess]: the hub's .htaccess and 404 page in, then the link gate over the result.
docs_site_stage() {
  local site="${1:?usage: docs-site.sh stage <site dir> [--allow FILE] [--no-htaccess]}" htaccess=1 templates
  local -a gate=()
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow) gate+=(--allow "${2:?--allow needs a file}"); shift 2 ;;
      --no-htaccess) htaccess=0; shift ;;
      *) die "bad argument" "stage takes --allow FILE and --no-htaccess, got '$1'." ;;
    esac
  done
  [ -d "${site}" ] || die "no site" "'${site}' is not a directory: the build wrote its site somewhere else, or nothing."
  templates="${DOCS_SITE_HUB}/linux/webserver/templates"
  if [ "${htaccess}" -eq 1 ]; then
    [ ! -e "${site}/.htaccess" ] || die "the site ships a .htaccess" "the hub owns a docs site's .htaccess; pass htaccess: false to publish your own."
    cp "${templates}/docs-site.htaccess" "${site}/.htaccess"
    [ -e "${site}/404.html" ] || cp "${templates}/docs-site-404.html" "${site}/404.html"
  fi
  "${PYTHON:-python3}" "${DOCS_SITE_HUB}/linux/scripts/verify_site_links.py" "${site}" ${gate[@]+"${gate[@]}"}
}

# check <site> [--if-chrome]: every sidebar toggle clicked in headless Chrome; --if-chrome skips where the image has no Chrome.
docs_site_check() {
  local site="${1:?usage: docs-site.sh check <site dir> [--if-chrome]}"
  case "${2:-}" in
    '') ;;
    --if-chrome)
      if [ -z "${CHROME_EXECUTABLE:-}" ]; then
        printf 'docs-site: sidebar check skipped: no CHROME_EXECUTABLE (the family image sets it on amd64 and arm64)
'
        return 0
      fi
      ;;
    *) die "bad argument" "check takes --if-chrome, got '$2'." ;;
  esac
  command -v node >/dev/null 2>&1 || die "no node" "the sidebar check runs on node, which the family image carries."
  node "${DOCS_SITE_HUB}/linux/scripts/check-docs-sidebars.js" "${site}"
}

case "${1:-}" in
  plan) docs_site_plan ;;
  build) shift; docs_site_build "$@" ;;
  check) shift; docs_site_check "$@" ;;
  stage) shift; docs_site_stage "$@" ;;
  *) die "usage" "docs-site.sh plan | build [<site dir>] | check <site dir> [--if-chrome] | stage <site dir> [--allow FILE] [--no-htaccess]" ;;
esac
