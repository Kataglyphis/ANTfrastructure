#!/usr/bin/env bash
# Real ty fixtures prove the strict scopes; image-only imports remain in the full reports.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf -- "${ROOT}"' EXIT

mkdir -p "${ROOT}/linux/scripts/01-core" "${ROOT}/linux/scripts/tests" \
  "${ROOT}/linux/scripts/05-frameworks/flutter" "${ROOT}/linux/webserver/scripts" "${ROOT}/docs/scripts" \
  "${ROOT}/windows/scripts/certificates" "${ROOT}/shared/python" \
  "${ROOT}/linux/llm-stack/tests" "${ROOT}/linux/llm-stack/gateway" \
  "${ROOT}/linux/scripts/02-toolchain/python" \
  "${ROOT}/linux/scripts/lib" "${ROOT}/linux/host-config" "${ROOT}/quality" \
  "${ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis"
cp "${S}/lint-python-types.sh" "${ROOT}/linux/scripts/"
cp "${S}/01-core/load-versions-env.sh" "${ROOT}/linux/scripts/01-core/"
cp "${S}/01-core/load-ty-tool.sh" "${ROOT}/linux/scripts/01-core/"
cp "${S}/../../quality/pyproject.toml" "${S}/../../quality/uv.lock" "${ROOT}/quality/"
sed -n '/^\(TY\|RUFF\)_VERSION=/p' "${S}/01-core/tool-pins.env" > "${ROOT}/linux/scripts/01-core/tool-pins.env"
git -C "${ROOT}" init -q

_run() {
  local out rc=0
  out="$(bash "${ROOT}/linux/scripts/lint-python-types.sh" "$@" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

_set_answer() {
  printf 'def answer() -> int:\n    return %s\n' "$2" > "$1"
}

_assert_clean_quality() {
  t_assert_contains "$1" "ty quality gate: clean (37 files)"
  t_assert_contains "$1" "ty Windows gate: clean (1 files)"
  t_assert_contains "$1" "rc=0"
}

t_case "the pinned ty checks tracked quality scripts and writes all reports under logs"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/bump_tools.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/bump_fetch.py"
printf 'from sphinx_kataglyphis import value\nRESULT: int = value()\n' > "${ROOT}/docs/conf.py"
_set_answer "${ROOT}/windows/scripts/subject.py" 42
_set_answer "${ROOT}/linux/scripts/verify_subject.py" 42
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" 42
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/typed_subject.py" 42
printf 'from playwright.sync_api import Page\ndef title(page: Page) -> str:\n    return page.title()\n' > "${ROOT}/linux/webserver/scripts/flutter_capture_console_errors.py"
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" 42
printf 'import pytest\nimport yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/llm-stack/tests/typed_subject.py"
printf 'import pytest\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py"
printf 'import yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_audit.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_cmake.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/llm-stack/gateway/render_apisix.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/llm-stack/tests/test_gateway_render.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/verify_code_dupes.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/verify_doc_dupes.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/sync_versions.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/host-config/ghcr_metadata.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/manifest-base-layer.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/registry-config-label.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/registry-digest.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/02-toolchain/oci-layers-extract.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/02-toolchain/python/wheel-smoke.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/tests/test-wheel-rewrite.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/verify_readme_length.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_locator.py"
for target in develop_red.py layer-audit.py verify_large_files.py verify_masked_assignments.py; do
  printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/${target}"
done
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_package_names.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_comment_size.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_gate_registry.py"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/gate_scope.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/quality_allow.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/extract_embedded_python.py"
git -c core.autocrlf=false -C "${ROOT}" add .
printf 'def value() -> int:\n    return 42\n' > "${ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis/__init__.py"
out="$(_run)"
_assert_clean_quality "${out}"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-quality-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-linux.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-windows.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-windows-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-annotations.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-annotations-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-private-returns-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-parameters-returns-gate.txt"
t_assert_contains "${out}" "Ruff signature annotation gate: clean (40 files)"
t_assert_contains "${out}" "Ruff private return gate: clean (40 files)"
t_assert_contains "${out}" "Ruff parameter and public return gate: clean (24 files)"

t_case "ambient checker versions cannot replace the repository pins"
out="$(TY_VERSION=bogus RUFF_VERSION=bogus _run)"
_assert_clean_quality "${out}"

t_case "docs configuration is checked against the pinned theme source"
out="$(_run --docs-conf)"
t_assert_contains "${out}" "ty docs configuration gate: clean (1 files)"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-docs-conf-gate.txt"
t_assert_contains "${out}" "rc=0"

t_case "a docs configuration type error fails the strict theme-aware gate"
printf 'from sphinx_kataglyphis import value\nRESULT: int = "wrong"\n' > "${ROOT}/docs/conf.py"
out="$(_run --docs-conf)"
t_assert_contains "${out}" "ty docs configuration gate failed (exit 1)"
t_assert_contains "${out}" "docs/conf.py"
t_assert_contains "${out}" "rc=1"
printf 'from sphinx_kataglyphis import value\nRESULT: int = value()\n' > "${ROOT}/docs/conf.py"

t_case "missing theme source fails before a green docs verdict"
rm "${ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis/__init__.py"
out="$(_run --docs-conf)"
t_assert_contains "${out}" "Pinned DocumANTation theme source is missing"
t_assert_contains "${out}" "rc=2"
printf 'def value() -> int:\n    return 42\n' > "${ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis/__init__.py"

t_case "the locked quality environment resolves test and parser imports"
t_assert_ok test -d "${ROOT}/quality/.venv"
t_assert_no_grep "${ROOT}/logs/code-quality/ty-quality-gate.txt" 'unresolved-import'

t_case "a wrong Playwright API return type fails the strict browser-smoke scope"
printf 'from playwright.sync_api import Page\ndef title(page: Page) -> int:\n    return page.title()\n' > "${ROOT}/linux/webserver/scripts/flutter_capture_console_errors.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "flutter_capture_console_errors.py"
t_assert_contains "${out}" "invalid-return-type"
t_assert_contains "${out}" "rc=1"
printf 'from playwright.sync_api import Page\ndef title(page: Page) -> str:\n    return page.title()\n' > "${ROOT}/linux/webserver/scripts/flutter_capture_console_errors.py"

t_case "a return type mismatch fails the strict gate"
_set_answer "${ROOT}/docs/scripts/subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "invalid-return-type"
t_assert_contains "${out}" "rc=1"

t_case "a verifier type mismatch is inside the strict scope"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/linux/scripts/verify_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "verify_subject.py"
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/linux/scripts/verify_subject.py" 42

t_case "a test helper type mismatch is inside the strict scope"
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "typed_subject.py"
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" 42

t_case "a framework source mismatch is inside the strict scope"
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/typed_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "05-frameworks"
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/typed_subject.py" 42

t_case "a type error in the LLM tests fails the expanded strict scope"
printf 'import pytest\nimport yaml\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/llm-stack/tests/typed_subject.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "llm-stack/tests/typed_subject.py"
t_assert_contains "${out}" "rc=1"
printf 'import pytest\nimport yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/llm-stack/tests/typed_subject.py"

t_case "a type error in the Python wheel tests fails the expanded strict scope"
printf 'import pytest\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "free-threaded-wheel-tests.py"
t_assert_contains "${out}" "rc=1"
printf 'import pytest\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py"

t_case "a type error in the audit script fails the expanded strict scope"
printf 'import yaml\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/renovate_audit.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "renovate_audit.py"
t_assert_contains "${out}" "rc=1"
printf 'import yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_audit.py"

t_case "a missing private Renovate return fails the focused Ruff gate"
printf 'def _plan():\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff private return gate failed (exit 1)"
t_assert_contains "${out}" "ANN202"
t_assert_contains "${out}" "rc=1"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"

t_case "a missing private Windows return fails the tracked-tree Ruff gate"
printf 'def _answer():\n    return 42\n' > "${ROOT}/windows/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff private return gate failed (exit 1)"
t_assert_contains "${out}" "windows/scripts/subject.py"
t_assert_contains "${out}" "ANN202"
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/windows/scripts/subject.py" 42

t_case "missing private verifier returns fail the focused Ruff gate"
for target in verify_package_names verify_comment_size verify_gate_registry; do
  printf 'def _check():\n    return 42\n' > "${ROOT}/linux/scripts/${target}.py"
  out="$(_run)"
  t_assert_contains "${out}" "Ruff private return gate failed (exit 1)"
  t_assert_contains "${out}" "ANN202"
  t_assert_contains "${out}" "rc=1"
  printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/${target}.py"
done

t_case "each selected Python file fails on missing parameter and public return types"
for target in linux/scripts/develop_red.py linux/scripts/layer-audit.py \
  linux/scripts/renovate_audit.py linux/scripts/renovate_cmake.py linux/scripts/renovate_locator.py linux/scripts/renovate_planner.py \
  linux/scripts/verify_large_files.py linux/scripts/verify_masked_assignments.py \
  linux/scripts/verify_package_names.py \
  linux/llm-stack/gateway/render_apisix.py linux/llm-stack/tests/test_gateway_render.py \
  docs/scripts/verify_code_dupes.py docs/scripts/verify_doc_dupes.py \
  docs/scripts/sync_versions.py docs/scripts/bump_tools.py docs/scripts/bump_fetch.py \
  linux/host-config/ghcr_metadata.py \
  linux/scripts/01-core/manifest-base-layer.py linux/scripts/01-core/registry-config-label.py \
  linux/scripts/01-core/registry-digest.py linux/scripts/02-toolchain/oci-layers-extract.py \
  linux/scripts/02-toolchain/python/wheel-smoke.py linux/scripts/tests/test-wheel-rewrite.py \
  linux/scripts/verify_readme_length.py; do
  printf 'def answer(value):\n    return value\n' > "${ROOT}/${target}"
  out="$(_run)"
  t_assert_contains "${out}" "Ruff parameter and public return gate failed (exit 1)"
  t_assert_contains "${out}" "${target}"
  t_assert_contains "${out}" "ANN001"
  t_assert_contains "${out}" "ANN201"
  t_assert_contains "${out}" "rc=1"
  printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/${target}"
done

t_case "a type error in the Markdown parser fails the expanded strict scope"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "dartdoc-guides.py"
t_assert_contains "${out}" "rc=1"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"

t_case "a Windows source mismatch is visible and fails the Windows type gate"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "Windows Python report: findings (2 files)"
t_assert_contains "${out}" "ty Windows gate failed (exit 1)"
t_assert_contains "${out}" "rc=1"
t_assert_grep "${ROOT}/logs/code-quality/ty-windows.txt" 'invalid-return-type'
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" 42

t_case "missing annotations are reported without claiming ty requires them"
printf 'def answer():\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
_set_answer "${ROOT}/windows/scripts/subject.py" 42
out="$(_run)"
t_assert_contains "${out}" "Ruff annotation report: findings"
t_assert_contains "${out}" "ty quality gate: clean"
t_assert_contains "${out}" "rc=0"
t_assert_grep "${ROOT}/logs/code-quality/ruff-annotations.txt" 'ANN201'

t_case "missing parameter annotations are reported without failing the type gate"
printf 'def answer(value) -> int:\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff annotation report: findings"
t_assert_contains "${out}" "ty quality gate: clean"
t_assert_contains "${out}" "rc=0"
t_assert_grep "${ROOT}/logs/code-quality/ruff-annotations.txt" 'ANN001'

t_case "a staticmethod without a return annotation fails the full tracked-tree gate"
printf 'class Answer:\n    @staticmethod\n    def value():\n        return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN205"
t_assert_contains "${out}" "rc=1"

t_case "a classmethod without a return annotation fails the full tracked-tree gate"
printf 'class Answer:\n    @classmethod\n    def value(cls):\n        return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN206"
t_assert_contains "${out}" "rc=1"

t_case "a constructor without a return annotation fails the full tracked-tree gate"
printf 'class Answer:\n    def __init__(self):\n        self.value = 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN204"
t_assert_contains "${out}" "rc=1"

t_case "unannotated variadic positional arguments fail the full tracked-tree gate"
printf 'def answer(*values) -> int:\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN002"
t_assert_contains "${out}" "rc=1"

t_case "unannotated variadic keyword arguments fail the full tracked-tree gate"
printf 'def answer(**values) -> int:\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN003"
t_assert_contains "${out}" "rc=1"

t_summary
