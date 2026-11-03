#!/usr/bin/env bash
# lib/docs-build.sh's docs_build_main is consumer API with no caller here; these cases pin its argv, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
LIB="${TESTS_DIR}/../lib/docs-build.sh"
LOG="${_work}/argv.log"
declare out rc

mkdir -p "${_work}/proj/docs/source" "${_work}/svg"
printf '<svg/>\n' > "${_work}/svg/flow.svg"
printf '#!/usr/bin/env bash\necho "create ${PWD##*/}" >> %q\nmkdir -p .venv/bin\nprintf "echo activated >> %q\\n" > .venv/bin/activate\n' "${LOG}" "${LOG}" > "${_work}/create.sh"
printf '#!/usr/bin/env bash\necho "install ${PWD##*/}" >> %q\n' "${LOG}" > "${_work}/install.sh"
chmod +x "${_work}/create.sh" "${_work}/install.sh"
lc_stub make "printf 'make-env %s|%s\n' \"\${PWD##*/}\" \"\${SPHINXOPTS}\" >> $(printf '%q' "${LOG}"); [ \"\$1\" != html ] || [ -e $(printf '%q' "${_work}/rc/no-index") ] || { mkdir -p build/html; : > build/html/index.html; }; exit $(lc_status make)"
lc_stub python3 'printf "gen-cwd %s\n" "${PWD##*/}" >> "${0%/bin/*}/argv.log"'
# The sidebar click needs Chrome; without CHROME_EXECUTABLE docs-site.sh skips it, as the family image does where it has none.
ENV="unset CHROME_EXECUTABLE; DOCS_BUILD_PROJECT_ROOT=$(printf '%q' "${_work}/proj") DOCS_BUILD_UV_VENV_CREATE_SCRIPT=$(printf '%q' "${_work}/create.sh") DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT=$(printf '%q' "${_work}/install.sh")"

# <status> <snippet>: the snippet ends with that status and no success line.
_assert_step_fails() {
  lc_call out rc "${LIB}" "$2"
  t_assert_eq "$1" "${rc}" "$2"
  t_assert_eq "0" "$(printf '%s\n' "${out}" | grep -c -e 'completed successfully')" "no success line after a failed step"
}

t_case "docs_build_main needs both venv bootstrap scripts"
lc_expect 1 "No venv bootstrap scripts configured (set DOCS_BUILD_UV_VENV_CREATE_SCRIPT and DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT)." "${LIB}" 'docs_build_main'

t_case "the full pipeline: venv in the root, SVGs staged, generator in source/, html then linkcheck"
lc_reset
lc_call out rc "${LIB}" "${ENV} DOCS_BUILD_SVG_SOURCE_DIR=$(printf '%q' "${_work}/svg") DOCS_BUILD_GENERATOR_SCRIPT=gen.py DOCS_BUILD_PYTHON=python3 docs_build_main"
t_assert_eq "0" "${rc}"
t_assert_eq "create proj
install proj
activated
python3 gen.py
gen-cwd source
make html
make-env docs|-W --keep-going
make linkcheck
make-env docs|-W --keep-going" "$(lc_argv)"
t_assert_ok test -f "${_work}/proj/docs/source/_static/flow.svg"
t_assert_contains "${out}" "docs-site: sidebar check skipped: no CHROME_EXECUTABLE"
t_assert_contains "${out}" "Documentation build completed successfully"

t_case "DOCS_BUILD_TARGETS and an empty DOCS_BUILD_SPHINXOPTS are taken as given"
lc_reset
lc_call out rc "${LIB}" "${ENV} DOCS_BUILD_TARGETS=(dirhtml); DOCS_BUILD_SPHINXOPTS= docs_build_main"
t_assert_eq "0" "${rc}"
t_assert_eq "make dirhtml
make-env docs|" "$(lc_argv | grep -e '^make')"

t_case "an html build without build/html/index.html fails: the Makefile's BUILDDIR must be build"
rm -f "${_work}/proj/docs/build/html/index.html"
lc_fail no-index 1
lc_expect 1 "build/html/index.html after make html: the docs Makefile's BUILDDIR must be build" "${LIB}" "${ENV} docs_build_main"
lc_pass no-index

t_case "a bootstrap that made no venv fails before Sphinx"
lc_expect 1 "No virtualenv to activate at ${_work}/none." "${LIB}" "${ENV} DOCS_BUILD_VENV_DIR=$(printf '%q' "${_work}/none") docs_build_main"

t_case "a failed make stops the pipeline with its status, with or without errexit"
lc_fail make 2
lc_reset
_assert_step_fails 2 "set -e; ${ENV} docs_build_main"
t_assert_eq "make html" "$(lc_argv | grep -e '^make ')" "linkcheck never starts after a failed html"
_assert_step_fails 2 "${ENV} docs_build_main"
_assert_step_fails 2 "set -e; ${ENV} docs_build_main || exit \$?"
lc_pass make

t_case "every earlier step stops the pipeline without errexit"
_assert_step_fails 1 "${ENV} DOCS_BUILD_UV_VENV_CREATE_SCRIPT=false docs_build_main"
_assert_step_fails 1 "${ENV} DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT=false docs_build_main"
mkdir -p "${_work}/badvenv/bin" "${_work}/nosvg"
printf 'return 9\n' > "${_work}/badvenv/bin/activate"
_assert_step_fails 9 "${ENV} DOCS_BUILD_VENV_DIR=$(printf '%q' "${_work}/badvenv") docs_build_main"
_assert_step_fails 1 "${ENV} DOCS_BUILD_SVG_SOURCE_DIR=$(printf '%q' "${_work}/nosvg") docs_build_main"
_assert_step_fails 1 "${ENV} DOCS_BUILD_GENERATOR_SCRIPT=gen.py DOCS_BUILD_PYTHON=false docs_build_main"

t_case "a failed sidebar check stops the pipeline after make html"
lc_reset
_assert_step_fails 4 "docs_build_check_sidebars() { return 4; }; ${ENV} docs_build_main"
t_assert_eq "make html" "$(lc_argv | grep -e '^make ')" "linkcheck never starts after a failed check"

t_summary
