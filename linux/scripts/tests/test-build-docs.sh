#!/usr/bin/env bash
# Fake uv and theme metadata isolate branch failures; this suite does not resolve PyPI or render Sphinx.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../build-docs.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
t_skip_unless "a POSIX python3" t_posix_python
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT

FNS="$(t_fn_src "${SUBJECT}" check_docs_lock && t_fn_src "${SUBJECT}" docs_venv && t_fn_src "${SUBJECT}" theme_requirements_met)" || exit 1
# branch [VAR=value...]: which way docs_venv goes, with every step it calls stubbed to say its name.
branch() {
  env VENV_DIR="${w}/venv" REPO_ROOT="${REPO_ROOT}" "$@" bash -c "
    err() { echo \"err: \$*\"; exit 1; }
    info() { :; }
    image_docs_venv() { echo image; }
    theme_requirements_met() { return 0; }
    uv() {
      case \"\$1\" in
        lock) printf 'lock:%s\\n' \"\$*\"; [ \"\${STUB_LOCK_FAIL:-0}\" != 1 ] ;;
        sync) printf 'sync:%s:%s\\n' \"\$UV_PROJECT_ENVIRONMENT\" \"\$*\"; [ \"\${STUB_UV_FAIL:-0}\" != 1 ] ;;
      esac
    }
    $(t_fn_src "${SUBJECT}" check_docs_lock)
    $(t_fn_src "${SUBJECT}" docs_venv)
    docs_venv" 2>&1
}
mkdir -p "${w}/opt-venv"

t_case "the image builds offline; CI without it refuses; a workstation syncs the docs lock"
lock_check="lock:lock --project ${REPO_ROOT}/docs --check --offline"
t_assert_eq "${lock_check}"$'\nimage' "$(branch IMAGE_VENV="${w}/opt-venv" CI=true)"
t_assert_eq "err: no ${w}/none: the docs build in the family image (build-docs.yml), never from PyPI in CI" "$(branch IMAGE_VENV="${w}/none" CI=true)"
t_assert_eq "${lock_check}"$'\n'"sync:${w}/venv:sync --project ${REPO_ROOT}/docs --locked" "$(branch IMAGE_VENV="${w}/none" CI=)"
branch IMAGE_VENV="${w}/none" CI= STUB_UV_FAIL=1 > "${w}/failed-sync"; rc=$?
t_assert_eq 1 "$rc" "a failed locked sync must fail the docs build"
branch IMAGE_VENV="${w}/opt-venv" CI=true STUB_LOCK_FAIL=1 > "${w}/failed-lock"; rc=$?
t_assert_eq 1 "$rc" "a stale docs lock must stop the image build"
t_assert_contains "$(cat "${w}/failed-lock")" "docs/uv.lock is missing or stale"
t_assert_fails grep -q -e '^image$' "${w}/failed-lock"

# A stand-in theme distribution; python is the host's with it on the path.
site="${w}/site"
mkdir -p "${site}/sphinx_kataglyphis_theme-0.1.0.dist-info" "${w}/venv/bin"
mkdir -p "${site}/h4a_present-1.5.0.dist-info"
printf 'Metadata-Version: 2.1\nName: h4a-present\nVersion: 1.5.0\n' > "${site}/h4a_present-1.5.0.dist-info/METADATA"
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
t_assert_eq met "$(needs 'h4a-present>=1')"
t_assert_contains "$(needs 'h4a-present>=1' 'h4a-not-a-package>=1')" "h4a-not-a-package>=1 (absent)"
t_assert_contains "$(needs 'h4a-present>=9999')" "h4a-present>=9999 (the image has"
t_assert_eq met "$(needs 'h4a-present>=1' 'h4a-not-a-package; extra == "dev"')"

t_summary
