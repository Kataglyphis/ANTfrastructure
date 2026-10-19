#!/usr/bin/env bash
# dartdoc-guides.py's links: a guide link keeps its anchor, any other *.md link goes to GitHub. See docs/shared-script-libraries.md#dartdoc-buildsh--theme-and-enrich-a-dart-doc-site
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="$(cd "${TESTS_DIR}/../lib" && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# The link code reads HTML, not Markdown, and the runner carries no markdown-it-py: a stand-in parser.
mkdir -p "${_work}/stub/markdown_it"
printf 'class MarkdownIt:\n    def __init__(self, *args, **kwargs):\n        pass\n\n    def enable(self, *args):\n        return self\n' \
  > "${_work}/stub/markdown_it/__init__.py"

# _call <python expression over `guides`> [args...]: prints the expression's value; sys.argv[2:] are the args.
_call() {
  local expr="$1"
  shift
  (cd "${_work}/stub" && "${PY}" - "${LIB}/dartdoc-guides.py" "${expr}" "$@" <<'PY'
import importlib.util
import sys

sys.path.insert(0, ".")
spec = importlib.util.spec_from_file_location("guides", sys.argv[1])
guides = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guides)
args = sys.argv[3:]
print(eval(sys.argv[2], {"guides": guides, "args": args}))
PY
  )
}

# _href <guide source> <href> [repo URL]: the href the renderer writes for that link in that guide.
_href() {
  _call 'guides.rewrite_md_links("<a href=\"%s\">x</a>" % args[1], guides.LinkTargets({"pages/src/getting-started.md": "guide-getting-started.html", "pages/src/README.md": "guide-docs-readme.html"}, args[2] if len(args) > 2 else "", [("third_party/ANTfrastructure", "https://github.com/Kataglyphis/ANTfrastructure")]), args[0]).split("\"")[1]' "$@"
}
REPO=https://github.com/Kataglyphis/OmniAccelerANT

t_case "a link to a guide, anchored or not, goes to that guide's page"
t_assert_eq "guide-getting-started.html#known-issues" "$(_href pages/src/overview.md 'getting-started.md#known-issues' "${REPO}")" \
  "the anchor was dropped with the rewrite, and the .md link 404ed on the site"
t_assert_eq "guide-getting-started.html" "$(_href pages/src/overview.md getting-started.md "${REPO}")"
t_assert_eq "guide-getting-started.html" "$(_href pages/INTRODUCTION.md src/getting-started.md "${REPO}")" \
  "a guide is found by the path the link resolves to, from any directory"
t_assert_eq "guide-docs-readme.html" "$(_href pages/src/overview.md README.md "${REPO}")" \
  "a guide whose slug is not its file name"

t_case "any other *.md link goes to the file on GitHub, on develop"
t_assert_eq "${REPO}/blob/develop/AGENTS.md" "$(_href pages/INTRODUCTION.md ../AGENTS.md "${REPO}")" \
  "not to a guide-AGENTS.html nothing renders"
t_assert_eq "${REPO}/blob/develop/AGENTS.md#5-build-run-test" "$(_href pages/src/testing.md '../../AGENTS.md#5-build-run-test' "${REPO}")"
t_assert_eq "${REPO}/blob/develop/README.md" "$(_href pages/src/overview.md ../../README.md "${REPO}")" \
  "the root README is not the pages/src/README.md guide"
t_assert_eq "https://github.com/Kataglyphis/ANTfrastructure/blob/develop/shared/README.md#x" \
  "$(_href pages/src/platforms.md '../../third_party/ANTfrastructure/shared/README.md#x' "${REPO}")" \
  "GitHub does not follow a submodule, so the submodule's own repository"

t_case "absolute, same-page and non-Markdown links are left alone"
t_assert_eq "https://example.org/a.md" "$(_href pages/x.md https://example.org/a.md "${REPO}")"
t_assert_eq "#local" "$(_href pages/x.md '#local' "${REPO}")"
t_assert_eq "images/a.png" "$(_href pages/x.md images/a.png "${REPO}")"

t_case "a link that cannot be placed fails the render instead of shipping a 404"
t_assert_eq 1 "$(t_rc _href pages/src/overview.md ../../AGENTS.md)" "no repository URL is known"
t_assert_contains "$(t_out _href pages/src/overview.md ../../AGENTS.md)" "DARTDOC_BUILD_REPO_URL"
t_assert_eq 1 "$(t_rc _href pages/x.md ../../outside.md "${REPO}")" "a link out of the repository"

t_case "the repository URL comes from any GitHub spelling of origin"
t_assert_eq "${REPO}" "$(_call 'guides.github_url(args[0])' git@github.com:Kataglyphis/OmniAccelerANT.git)"
t_assert_eq "${REPO}" "$(_call 'guides.github_url(args[0])' https://github.com/Kataglyphis/OmniAccelerANT.git)"
t_assert_eq "${REPO}" "$(_call 'guides.github_url(args[0])' https://github.com/Kataglyphis/OmniAccelerANT)"
t_assert_eq "" "$(_call 'guides.github_url(args[0])' https://gitlab.com/Kataglyphis/OmniAccelerANT.git)"
d="${_work}/checkout"
git init -q "${d}"
git -C "${d}" remote add origin https://github.com/Kataglyphis/OmniAccelerANT.git
printf '[submodule "hub"]\n\tpath = third_party/ANTfrastructure\n\turl = https://github.com/Kataglyphis/ANTfrastructure.git\n' > "${d}/.gitmodules"
t_assert_eq "${REPO}" "$(_call 'guides.origin_url(args[0])' "${d}")"
t_assert_eq "[('third_party/ANTfrastructure', 'https://github.com/Kataglyphis/ANTfrastructure')]" \
  "$(_call 'guides.submodule_urls(args[0])' "${d}")"

t_case "a heading's anchor is GitHub's, so a link written for GitHub lands"
t_assert_eq "6-build-api-docs" "$(_call 'guides.slugify(args[0])' '6. Build API docs')"
t_assert_eq "run-lint-gatessh--seven-gates" "$(_call 'guides.slugify(args[0])' '`run-lint-gates.sh` — seven gates')"

t_case "dartdoc-build.sh hands the renderer each guide's source and the project root"
_cfg="${_work}/render.cfg"
# shellcheck disable=SC2034  # the sourced _dartdoc_build_write_render_config reads them
(
  # shellcheck source=../lib/dartdoc-build.sh
  source "${LIB}/dartdoc-build.sh"
  DARTDOC_BUILD_PROJECT_ROOT=/repo
  DARTDOC_BUILD_REPO_URL="${REPO}"
  DARTDOC_BUILD_GUIDES=("/repo/pages/src/overview.md|overview|Overview")
  _dartdoc_build_write_render_config "${_cfg}"
)
t_assert_eq "('/repo', '${REPO}', [('overview', 'Overview')], {'overview': '/repo/pages/src/overview.md'})" \
  "$(_call '(lambda c: (c["project_root"], c["repo_url"], c["guides"], c["sources"]))(guides.load_config(args[0]))' "${_cfg}")"

t_summary
