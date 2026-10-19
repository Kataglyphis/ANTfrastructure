#!/usr/bin/env bash
# build-docs.sh: the image's Sphinx stack offline, never PyPI in CI, and the theme's requirements checked by name. See docs/project-info.md#building-the-hubs-docs
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../build-docs.sh"
t_skip_unless "a POSIX python3" t_posix_python
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT

FNS="$(t_fn_src "${SUBJECT}" docs_venv && t_fn_src "${SUBJECT}" theme_requirements_met)" || exit 1
# branch [VAR=value...]: which way docs_venv goes, with every step it calls stubbed to say its name.
branch() {
  env "$@" bash -c "
    err() { echo \"err: \$*\"; exit 1; }
    info() { :; }
    image_docs_venv() { echo image; }
    theme_requirements_met() { return 0; }
    uv_venv_create() { echo pypi; }
    uv_pip_install_requirements() { :; }
    $(t_fn_src "${SUBJECT}" docs_venv)
    docs_venv" 2>&1
}
mkdir -p "${w}/opt-venv"

t_case "the image builds from its own stack; CI without it refuses; a workstation without it takes PyPI"
t_assert_eq image "$(branch IMAGE_VENV="${w}/opt-venv" CI=true)"
t_assert_contains "$(branch IMAGE_VENV="${w}/none" CI=true)" "err: no ${w}/none: the docs build in the family image"
t_assert_eq pypi "$(branch IMAGE_VENV="${w}/none" CI=)"

# A stand-in theme distribution; python is the host's with it on the path.
site="${w}/site"
mkdir -p "${site}/sphinx_kataglyphis_theme-0.1.0.dist-info" "${w}/venv/bin"
printf '#!/usr/bin/env bash\nPYTHONPATH="%s" exec python3 "$@"\n' "${site}" > "${w}/venv/bin/python"
chmod +x "${w}/venv/bin/python"
# needs <Requires-Dist line...>: the stand-in theme with those requirements; prints the check's verdict.
needs() {
  { printf 'Metadata-Version: 2.1\nName: sphinx-kataglyphis-theme\nVersion: 0.1.0\n'; printf 'Requires-Dist: %s\n' "$@"; } \
    > "${site}/sphinx_kataglyphis_theme-0.1.0.dist-info/METADATA"
  if VENV_DIR="${w}/venv" bash -c "${FNS}
theme_requirements_met" 2>&1; then echo met; fi
}
t_case "the theme's requirements: met, absent or too old, each named; an extra's are not asked for"
t_assert_eq met "$(needs 'pip>=1')"
t_assert_contains "$(needs 'pip>=1' 'h4a-not-a-package>=1')" "h4a-not-a-package>=1 (absent)"
t_assert_contains "$(needs 'pip>=9999')" "pip>=9999 (the image has"
t_assert_eq met "$(needs 'pip>=1' 'h4a-not-a-package; extra == "dev"')"

t_summary
