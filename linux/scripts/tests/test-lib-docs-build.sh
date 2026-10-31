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

t_case "a failed make stops an errexit caller; without errexit the pipeline still reports success (BACKLOG CON210)"
lc_fail make 2
lc_call out rc "${LIB}" "set -e; ${ENV} DOCS_BUILD_TARGETS=(linkcheck); docs_build_main"
t_assert_eq "2" "${rc}"
lc_expect 0 "Documentation build completed successfully" "${LIB}" "${ENV} DOCS_BUILD_TARGETS=(linkcheck); docs_build_main"
lc_pass make

t_summary
