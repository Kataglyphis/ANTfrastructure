#!/usr/bin/env bash
# Real ty fixtures prove strict scopes and dynamically discovered report verdicts.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf -- "${ROOT}"' EXIT

source_root="$(cd "${S}/../.." && pwd)"
find "${source_root}/linux" "${source_root}/docs" "${source_root}/windows" "${source_root}/shared" \
  -type d \( -name third_party -o -name node_modules -o -name .venv -o -name logs \
    -o \( -name build ! -path "${source_root}/windows/scripts/build" ! -path "${source_root}/linux/scripts/03-media/build" \) \) -prune \
  -o -type d -print0 > "${ROOT}/fixture-directories" || exit 1
while IFS= read -r -d '' directory; do
  mkdir -p "${ROOT}/${directory#"${source_root}/"}" || exit 1
done < "${ROOT}/fixture-directories"
rm "${ROOT}/fixture-directories"
mkdir -p "${ROOT}/quality" "${ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis"
cp "${S}/../Dockerfile.torch" "${ROOT}/linux/Dockerfile.torch"
cp "${S}/lint-python-types.sh" "${ROOT}/linux/scripts/"
cp "${S}/01-core/load-versions-env.sh" "${ROOT}/linux/scripts/01-core/"
cp "${S}/01-core/load-ty-tool.sh" "${ROOT}/linux/scripts/01-core/"
cp "${S}/../../quality/pyproject.toml" "${S}/../../quality/uv.lock" "${ROOT}/quality/"
sed -n '/^\(TY\|RUFF\)_VERSION=/p' "${S}/01-core/tool-pins.env" > "${ROOT}/linux/scripts/01-core/tool-pins.env"
git -C "${ROOT}" init -q

_run() {
  local out rc=0
  out="$(bash "${ROOT}/linux/scripts/lint-python-types.sh" "$@" 2>&1)" || rc=$?
  out="${out//\\//}"
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

_set_answer() {
  printf 'def answer() -> int:\n    return %s\n' "$2" > "$1"
}

_assert_clean_quality() {
  t_assert_contains "$1" "ty quality gate: clean (126 files)"
  t_assert_contains "$1" "ty Windows gate: clean (1 files)"
  t_assert_contains "$1" "Linux Python report: clean (126 files)"
  t_assert_contains "$1" "Windows Python report: clean (2 files)"
  t_assert_contains "$1" "rc=0"
}

t_case "the pinned ty checks tracked quality scripts and writes all reports under logs"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/bump_tools.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/bump_fetch.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/bump_images.py"
printf 'from sphinx_kataglyphis import value\nRESULT: int = value()\n' > "${ROOT}/docs/conf.py"
_set_answer "${ROOT}/windows/scripts/subject.py" 42
_set_answer "${ROOT}/linux/scripts/verify_subject.py" 42
_set_answer "${ROOT}/linux/scripts/verify_workflow_conventions.py" 42
_set_answer "${ROOT}/linux/scripts/verify_site_links.py" 42
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" 42
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/typed_subject.py" 42
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/fetch-fallback-fonts.py" 42
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/05-frameworks/flutter/check-web-artefacts.py"
_set_answer "${ROOT}/linux/scripts/03-media/runtime/ort-venv-census.py" 42
printf 'from playwright.sync_api import Page\ndef title(page: Page) -> str:\n    return page.title()\n' > "${ROOT}/linux/webserver/scripts/flutter_capture_console_errors.py"
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" 42
printf 'import numpy\nfrom ai_edge_litert import interpreter\ndef answer(value: int) -> int:\n    return value\n' > "${ROOT}/windows/scripts/build/litert-wheel-smoke.py"
_set_answer "${ROOT}/linux/llm-stack/tests/gateway_e2e/test_e2e_routing.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/gateway_e2e/test_e2e_shaping.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/gateway_e2e/gw_fake_lane.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/gateway_e2e/gw_harness.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/gateway_e2e/conftest.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/gateway_e2e/gw_client.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/gateway_e2e/test_e2e_ops.py" 42
_set_answer "${ROOT}/linux/scripts/tests/apt-update-selection-tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/guarded_link_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/test-image-acceptance.py" 42
_set_answer "${ROOT}/docs/scripts/bump_versions.py" 42
_set_answer "${ROOT}/linux/scripts/tests/header_discovery_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/qnn_query_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/chain-ort-fixtures.py" 42
_set_answer "${ROOT}/linux/scripts/tests/sudo-policy-tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/raw_pin_reader_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/cross_active_registration_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/compiler_candidate_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/media_file_set_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/media-pin-advisory-tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/directory_visitor_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/verified_installer_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/toolchain_download_loader_tests.py" 42
_set_answer "${ROOT}/linux/ansible/scripts/ansible_run_status.py" 42
printf 'import cv2\nimport torch\nimport torchvision\ndef answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/jetson-webcam/app.py"
_set_answer "${ROOT}/linux/scripts/tests/smoke-query-contract-tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/clang_job_policy_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/binfmt_probe_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/meson_dispatch_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/host_cargo_preparation_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/target_cargo_pipeline_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/host_python_pin_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/validator_probe_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/runtime_child_stop_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/wheel_tag_resolution_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/runtime_sdk_help_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/triplet_query_tests.py" 42
_set_answer "${ROOT}/linux/scripts/verify_advertised_keys.py" 42
_set_answer "${ROOT}/linux/scripts/tests/cli_help_exit_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/image_ref_cli_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/smoke_native_dispatch_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/nerdctl_service_receipt_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/binfmt_probe_controls.py" 42
_set_answer "${ROOT}/linux/scripts/tests/native_gcc_env_tests.py" 42
_set_answer "${ROOT}/linux/scripts/verify_dockerfile_env_order.py" 42
_set_answer "${ROOT}/linux/scripts/tests/test-image-consumer-bootstrap.py" 42
_set_answer "${ROOT}/linux/scripts/tests/npm_python_transport_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/python-provider-context-tests.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/test_serving_stack.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/conftest.py" 42
_set_answer "${ROOT}/linux/scripts/tests/libcamera-report-tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/consumer_quality_wiring_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/test-corrosion-toolchain.py" 42
_set_answer "${ROOT}/linux/scripts/tests/sudo_policy_closure_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/wheel_archive_transport_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/webdav_download_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/meson_bound_provider_tests.py" 42
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/flutter-trace-summary.py" 42
_set_answer "${ROOT}/linux/scripts/tests/wheelhouse_manifest_tests.py" 42
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/frontend-perf-report.py" 42
_set_answer "${ROOT}/linux/scripts/tests/chain_sibling_pid_tests.py" 42
_set_answer "${ROOT}/linux/scripts/tests/log_dir_consumer_tests.py" 42
_set_answer "${ROOT}/linux/llm-stack/tests/test_gateway_logtail.py" 42
printf 'from kataglyphis_webdavclient.webdavclient import WebDavClient\ndef answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/download-webdav-files.py"
printf 'import pytest\nimport yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/llm-stack/tests/typed_subject.py"
printf 'def answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/tests/lint_scope_init_tests.py"
printf 'def answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/tests/command_callback_scope_tests.py"
printf 'def answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/tests/onnx_fetch_receipt_tests.py"
printf 'def answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/tests/workflow-lane-query.py"
printf 'import pytest\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py"
printf 'import yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_audit.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/renovate_pep_git.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/renovate_uv_exports.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_cmake.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/llm-stack/gateway/render_apisix.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/llm-stack/tests/test_gateway_render.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/verify_code_dupes.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/verify_doc_dupes.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/sync_versions.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/host-config/ghcr_metadata.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/manifest-base-layer.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/manifest-annotation.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/registry-config-label.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/01-core/registry-digest.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/02-toolchain/oci-layers-extract.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/02-toolchain/python/wheel-smoke.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/tests/test-wheel-rewrite.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/verify_readme_length.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_locator.py"
for target in develop_red.py layer-audit.py verify_large_files.py verify_masked_assignments.py verify_code_complexity.py verify_code_size.py verify_trailing_conditional.py; do
  printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/${target}"
done
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_package_names.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_consumer_inventory.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_comment_size.py"
printf 'def _check(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/verify_shellcheck_warnings.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_gate_registry.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/verify_image_env.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/06-packaging/ort_census_probe.py"
printf 'import tvm\nimport numpy\nimport cv2\ndef answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/06-packaging/venv-version-probe.py"
printf 'def main() -> None:\n    pass\n' > "${ROOT}/linux/scripts/03-media/build/gstreamer/common/gst-python-build-config.py"
printf 'def cache_lock(cache: object) -> object:\n    return cache\n' > "${ROOT}/linux/scripts/lib/fetch-data-lock.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/verify_dead_functions.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/image-acceptance.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/docs/scripts/verify_mutations.py"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/gate_scope.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/quality_allow.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/extract_embedded_python.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/tests/fleet_dependency_tests.py"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/06-packaging/free-threaded-sysconfig-tools.py"
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
  t_assert_contains "${out}" "Ruff signature annotation gate: clean (133 files)"
  t_assert_contains "${out}" "Ruff private return gate: clean (133 files)"
  t_assert_contains "${out}" "Ruff parameter and public return gate: clean (123 files)"

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

t_case "a missing environment-specific source fails before generic reports can omit it"
mv "${ROOT}/linux/jetson-webcam/app.py" "${ROOT}/linux/jetson-webcam/app.py.hidden"
out="$(_run)"
t_assert_contains "${out}" "Separately checked Python source is missing on disk: linux/jetson-webcam/app.py"
t_assert_contains "${out}" "rc=2"
mv "${ROOT}/linux/jetson-webcam/app.py.hidden" "${ROOT}/linux/jetson-webcam/app.py"

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

t_case "a type error in the PEP git resolver fails the strict scope"
printf 'def answer(value: int) -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/renovate_pep_git.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "renovate_pep_git.py"
t_assert_contains "${out}" "invalid-return-type"
t_assert_contains "${out}" "rc=1"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/renovate_pep_git.py"

t_case "a missing private Renovate return fails the focused Ruff gate"
printf 'def _plan():\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff private return gate failed (exit 1)"
t_assert_contains "${out}" "ANN202"
t_assert_contains "${out}" "rc=1"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"

t_case "a type error in the uv export planner fails the strict scope"
printf 'def answer(value: int) -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/renovate_uv_exports.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "renovate_uv_exports.py"
t_assert_contains "${out}" "invalid-return-type"
printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/linux/scripts/renovate_uv_exports.py"

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

t_case "every selected Python file fails on missing parameter and public return types"
parameter_targets=(
  linux/scripts/tests/webdav_download_tests.py \
  linux/scripts/tests/meson_bound_provider_tests.py \
  linux/scripts/05-frameworks/flutter/flutter-trace-summary.py \
  linux/scripts/tests/wheelhouse_manifest_tests.py \
  linux/scripts/tests/chain_sibling_pid_tests.py \
  linux/scripts/tests/log_dir_consumer_tests.py \
  linux/llm-stack/tests/test_gateway_logtail.py \
  linux/scripts/01-core/download-webdav-files.py \
  linux/scripts/extract_embedded_python.py \
  linux/scripts/tests/test-corrosion-toolchain.py \
  linux/scripts/tests/sudo_policy_closure_tests.py \
  linux/scripts/tests/wheel_archive_transport_tests.py \
  linux/llm-stack/tests/test_serving_stack.py \
  linux/llm-stack/tests/conftest.py \
  linux/scripts/tests/libcamera-report-tests.py \
  linux/scripts/tests/consumer_quality_wiring_tests.py \
  linux/scripts/verify_dockerfile_env_order.py \
  linux/scripts/tests/test-image-consumer-bootstrap.py \
  linux/scripts/tests/npm_python_transport_tests.py \
  linux/scripts/tests/python-provider-context-tests.py \
  linux/scripts/tests/smoke_native_dispatch_tests.py \
  linux/scripts/tests/nerdctl_service_receipt_tests.py \
  linux/scripts/tests/binfmt_probe_controls.py \
  linux/scripts/tests/native_gcc_env_tests.py \
  linux/scripts/tests/triplet_query_tests.py \
  linux/scripts/verify_advertised_keys.py \
  linux/scripts/tests/cli_help_exit_tests.py \
  linux/scripts/tests/image_ref_cli_tests.py \
  linux/scripts/tests/validator_probe_tests.py \
  linux/scripts/tests/runtime_child_stop_tests.py \
  linux/scripts/tests/wheel_tag_resolution_tests.py \
  linux/scripts/tests/runtime_sdk_help_tests.py \
  linux/scripts/tests/host_python_pin_tests.py \
  linux/scripts/tests/host_cargo_preparation_tests.py \
  linux/scripts/tests/target_cargo_pipeline_tests.py \
  linux/scripts/tests/meson_dispatch_tests.py \
  linux/scripts/tests/binfmt_probe_tests.py \
  linux/scripts/05-frameworks/flutter/frontend-perf-report.py \
  linux/scripts/tests/clang_job_policy_tests.py \
  linux/scripts/tests/smoke-query-contract-tests.py \
  linux/jetson-webcam/app.py \
  linux/ansible/scripts/ansible_run_status.py \
  linux/scripts/develop_red.py linux/scripts/layer-audit.py \
  linux/scripts/renovate_audit.py linux/scripts/renovate_cmake.py linux/scripts/renovate_locator.py linux/scripts/renovate_pep_git.py linux/scripts/renovate_planner.py linux/scripts/renovate_uv_exports.py \
  linux/scripts/verify_large_files.py linux/scripts/verify_masked_assignments.py \
  linux/scripts/verify_consumer_inventory.py linux/scripts/verify_package_names.py \
  linux/llm-stack/gateway/render_apisix.py linux/llm-stack/tests/test_gateway_render.py \
  linux/llm-stack/tests/gateway_e2e/test_e2e_routing.py \
  linux/llm-stack/tests/gateway_e2e/test_e2e_shaping.py \
  linux/llm-stack/tests/gateway_e2e/gw_fake_lane.py \
  linux/llm-stack/tests/gateway_e2e/gw_harness.py \
  linux/llm-stack/tests/gateway_e2e/conftest.py \
  linux/llm-stack/tests/gateway_e2e/gw_client.py \
  linux/llm-stack/tests/gateway_e2e/test_e2e_ops.py \
  linux/scripts/tests/apt-update-selection-tests.py \
  linux/scripts/tests/guarded_link_tests.py \
  linux/scripts/tests/test-image-acceptance.py \
  docs/scripts/bump_versions.py \
  linux/webserver/scripts/flutter_capture_console_errors.py \
  linux/scripts/tests/header_discovery_tests.py \
  linux/scripts/tests/qnn_query_tests.py \
  linux/scripts/tests/chain-ort-fixtures.py \
  linux/scripts/tests/sudo-policy-tests.py \
  linux/scripts/tests/raw_pin_reader_tests.py \
  linux/scripts/tests/cross_active_registration_tests.py \
  linux/scripts/tests/compiler_candidate_tests.py \
  linux/scripts/tests/media_file_set_tests.py \
  linux/scripts/tests/media-pin-advisory-tests.py \
  linux/scripts/tests/directory_visitor_tests.py \
  linux/scripts/tests/verified_installer_tests.py \
  linux/scripts/tests/toolchain_download_loader_tests.py \
  linux/scripts/verify_workflow_conventions.py \
  linux/scripts/verify_site_links.py \
  linux/scripts/quality_allow.py \
  docs/scripts/verify_code_dupes.py docs/scripts/verify_doc_dupes.py \
  docs/scripts/sync_versions.py docs/scripts/bump_tools.py docs/scripts/bump_fetch.py docs/scripts/bump_images.py \
  linux/host-config/ghcr_metadata.py \
  linux/scripts/01-core/manifest-base-layer.py linux/scripts/01-core/manifest-annotation.py \
  linux/scripts/01-core/registry-config-label.py \
  linux/scripts/01-core/registry-digest.py linux/scripts/02-toolchain/oci-layers-extract.py \
  linux/scripts/tests/lint_scope_init_tests.py \
  linux/scripts/tests/command_callback_scope_tests.py \
  linux/scripts/tests/onnx_fetch_receipt_tests.py \
  linux/scripts/tests/workflow-lane-query.py \
  linux/scripts/02-toolchain/python/wheel-smoke.py linux/scripts/tests/test-wheel-rewrite.py \
  linux/scripts/verify_readme_length.py linux/scripts/verify_gate_registry.py \
  linux/scripts/verify_code_complexity.py linux/scripts/verify_code_size.py \
  linux/scripts/verify_trailing_conditional.py \
  linux/scripts/verify_image_env.py linux/scripts/verify_dead_functions.py \
  linux/scripts/verify_comment_size.py \
  linux/scripts/verify_shellcheck_warnings.py \
  linux/scripts/gate_scope.py \
  linux/scripts/lib/dartdoc-guides.py \
  linux/scripts/tests/fleet_dependency_tests.py \
  linux/scripts/06-packaging/free-threaded-sysconfig-tools.py \
  linux/scripts/06-packaging/ort_census_probe.py linux/scripts/06-packaging/venv-version-probe.py \
  linux/scripts/03-media/build/gstreamer/common/gst-python-build-config.py \
  linux/scripts/03-media/runtime/ort-venv-census.py \
  linux/scripts/05-frameworks/flutter/fetch-fallback-fonts.py \
  linux/scripts/05-frameworks/flutter/check-web-artefacts.py \
  linux/scripts/lib/fetch-data-lock.py \
  linux/scripts/image-acceptance.py \
  docs/scripts/verify_mutations.py
)
# One checker run must report both annotation rules for every selected file.
for target in "${parameter_targets[@]}"; do
  printf 'def answer(value):\n    return value\n' > "${ROOT}/${target}"
done
out="$(_run)"
t_assert_contains "${out}" "Ruff parameter and public return gate failed (exit 1)"
t_assert_contains "${out}" "ANN001"
t_assert_contains "${out}" "ANN201"
t_assert_contains "${out}" "rc=1"
for target in "${parameter_targets[@]}"; do
  t_assert_contains "${out}" "${target}"
  printf 'def answer(value: int) -> int:\n    return value\n' > "${ROOT}/${target}"
done
t_assert_eq "${#parameter_targets[@]}" "$(printf '%s\n' "${out}" | awk '/ANN001/ { count++ } END { print count + 0 }')" \
  "one missing-parameter diagnostic per selected file"
t_assert_eq "${#parameter_targets[@]}" "$(printf '%s\n' "${out}" | awk '/ANN201/ { count++ } END { print count + 0 }')" \
  "one missing-public-return diagnostic per selected file"

t_case "a type error in the Markdown parser fails the expanded strict scope"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "dartdoc-guides.py"
t_assert_contains "${out}" "rc=1"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"

t_case "a Windows source mismatch fails the strict Windows type gate"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty Windows gate failed (exit 1)"
t_assert_contains "${out}" "rc=1"
t_assert_grep "${ROOT}/logs/code-quality/ty-windows-gate.txt" 'invalid-return-type'
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" 42

t_case "a missing public return annotation outside the focused list fails the full Ruff report"
printf 'def answer():\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
_set_answer "${ROOT}/windows/scripts/subject.py" 42
out="$(_run)"
t_assert_contains "${out}" "Ruff annotation gate failed (exit 1)"
t_assert_contains "${out}" "rc=1"
t_assert_grep "${ROOT}/logs/code-quality/ruff-annotations.txt" 'ANN201'

t_case "a missing parameter annotation outside the focused list fails the full Ruff report"
printf 'def answer(value) -> int:\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff annotation gate failed (exit 1)"
t_assert_contains "${out}" "rc=1"
t_assert_grep "${ROOT}/logs/code-quality/ruff-annotations.txt" 'ANN001'

t_case "a new Linux source outside the fixed list fails the dynamic ty report"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
printf 'def answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/new_unscoped_quality.py"
git -C "${ROOT}" add -- linux/scripts/new_unscoped_quality.py
out="$(_run)"
t_assert_contains "${out}" "Linux Python report failed (exit 1)"
t_assert_grep "${ROOT}/logs/code-quality/ty-linux.txt" 'invalid-return-type'
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/linux/scripts/new_unscoped_quality.py" 42

t_case "a new Windows source outside the fixed list fails the dynamic ty report"
printf 'def answer() -> int:\n    return "wrong"\n' > "${ROOT}/windows/scripts/new_unscoped_quality.py"
git -C "${ROOT}" add -- windows/scripts/new_unscoped_quality.py
out="$(_run)"
t_assert_contains "${out}" "Windows Python report failed (exit 1)"
t_assert_grep "${ROOT}/logs/code-quality/ty-windows.txt" 'invalid-return-type'
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/windows/scripts/new_unscoped_quality.py" 42

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
