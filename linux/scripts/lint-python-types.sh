#!/usr/bin/env bash
# Compatible imports and annotations fail in CI; dependency-specific files use their build gates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}" || exit 1
case "${1:-}" in
  ''|--docs-conf) ;;
  *) echo "Unknown Python type scan mode: $1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Python type scan accepts at most one mode" >&2; exit 2; }

# shellcheck source=01-core/load-ty-tool.sh
. linux/scripts/01-core/load-ty-tool.sh
unset RUFF_VERSION
load_ty_tool linux/scripts/01-core/tool-pins.env
: "${RUFF_VERSION:?RUFF_VERSION is missing from tool-pins.env}"
command -v uv >/dev/null 2>&1 || { echo "uv is required for the locked Python type environment" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "A Git worktree is required for the Python type scan" >&2; exit 2; }
if [ "${1:-}" = --docs-conf ]; then
  theme="${ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme"
  [ -f "${theme}/sphinx_kataglyphis/__init__.py" ] || { echo "Pinned DocumANTation theme source is missing" >&2; exit 2; }
  mapfile -d '' -t docs_conf_files < <(git ls-files -z -- 'docs/conf.py')
  [ "${#docs_conf_files[@]}" -eq 1 ] || { echo "Tracked docs/conf.py is missing" >&2; exit 2; }
fi

quality_venv="${ROOT}/quality/.venv"
UV_PROJECT_ENVIRONMENT="${quality_venv}" uv sync --project "${ROOT}/quality" --locked --python 3.14
quality_python="${quality_venv}/bin/python"
if [ ! -f "${quality_python}" ]; then quality_python="${quality_venv}/Scripts/python.exe"; fi
[ -f "${quality_python}" ] || { echo "The locked Python type environment has no interpreter" >&2; exit 2; }

report_dir="${ROOT}/logs/code-quality"
mkdir -p "${report_dir}"
linux_report="${report_dir}/ty-linux.txt"
windows_report="${report_dir}/ty-windows.txt"
strict_report="${report_dir}/ty-quality-gate.txt"
windows_gate_report="${report_dir}/ty-windows-gate.txt"
annotations_report="${report_dir}/ruff-annotations.txt"
annotations_gate_report="${report_dir}/ruff-annotations-gate.txt"
private_returns_report="${report_dir}/ruff-private-returns-gate.txt"
parameter_returns_report="${report_dir}/ruff-parameters-returns-gate.txt"

mapfile -d '' -t py_files < <(git ls-files -z -- '*.py')
mapfile -d '' -t quality_files < <(git ls-files -z -- '.claude/hooks/*.py' 'docs/scripts/*.py' \
  'linux/ansible/scripts/*.py' 'linux/host-config/*.py' 'linux/llm-stack/gateway/*.py' \
  'linux/llm-stack/tests/*.py' \
  'linux/scripts/01-core/manifest-*.py' 'linux/scripts/01-core/registry-*.py' \
  'linux/scripts/02-toolchain/oci-layers-extract.py' \
  'linux/scripts/02-toolchain/registry-platform-digest.py' \
  'linux/scripts/02-toolchain/python/free-threaded-wheel.py' \
  'linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py' \
  'linux/scripts/02-toolchain/python/verify-test-reports.py' \
  'linux/scripts/02-toolchain/python/wheel-smoke.py' \
  'linux/scripts/03-media/*.py' \
  'linux/scripts/05-frameworks/*.py' \
  'linux/scripts/06-packaging/free-threaded-sysconfig-tools.py' \
  'linux/scripts/06-packaging/ort_census_probe.py' \
  'linux/scripts/06-packaging/python-app-selftest.py' \
  'linux/scripts/develop_red.py' 'linux/scripts/image-acceptance.py' \
  'linux/scripts/layer-audit.py' 'linux/scripts/lib/cmakelang-py315.py' \
  'linux/scripts/lib/fetch-data-lock.py' 'linux/scripts/lib/dartdoc-guides.py' \
  'linux/scripts/renovate_audit.py' 'linux/scripts/renovate_cmake.py' \
  'linux/scripts/renovate_locator.py' 'linux/scripts/renovate_pep_git.py' \
  'linux/scripts/renovate_planner.py' \
  'linux/scripts/verify_*.py' \
  'linux/scripts/tests/*.py' 'linux/scripts/gate_scope.py' 'linux/scripts/quality_allow.py' \
  'linux/scripts/extract_embedded_python.py' 'linux/webserver/scripts/*.py' 'shared/python/*.py')
mapfile -d '' -t windows_quality_files < <(git ls-files -z -- 'windows/scripts/certificates/*.py')
mapfile -d '' -t parameter_return_files < <(git ls-files -z -- \
  'linux/jetson-webcam/app.py' \
  'linux/ansible/scripts/ansible_run_status.py' \
  'linux/scripts/develop_red.py' 'linux/scripts/layer-audit.py' \
  'linux/scripts/renovate_audit.py' 'linux/scripts/renovate_cmake.py' 'linux/scripts/renovate_locator.py' \
  'linux/scripts/renovate_pep_git.py' 'linux/scripts/renovate_planner.py' \
  'linux/scripts/verify_large_files.py' 'linux/scripts/verify_masked_assignments.py' \
  'linux/scripts/verify_consumer_inventory.py' 'linux/scripts/verify_package_names.py' \
  'linux/scripts/01-core/download-webdav-files.py' \
  'linux/llm-stack/gateway/render_apisix.py' 'linux/llm-stack/tests/test_gateway_render.py' \
  'linux/llm-stack/tests/test_gateway_logtail.py' \
  'docs/scripts/verify_code_dupes.py' 'docs/scripts/verify_doc_dupes.py' \
  'docs/scripts/sync_versions.py' 'docs/scripts/bump_tools.py' 'docs/scripts/bump_fetch.py' 'docs/scripts/bump_images.py' \
  'linux/host-config/ghcr_metadata.py' \
  'linux/scripts/01-core/manifest-base-layer.py' 'linux/scripts/01-core/registry-config-label.py' \
  'linux/scripts/01-core/registry-digest.py' 'linux/scripts/02-toolchain/oci-layers-extract.py' \
  'linux/scripts/01-core/manifest-annotation.py' \
  'linux/scripts/02-toolchain/python/wheel-smoke.py' 'linux/scripts/tests/test-wheel-rewrite.py' \
  'linux/scripts/tests/lint_scope_init_tests.py' \
  'linux/scripts/tests/command_callback_scope_tests.py' \
  'linux/scripts/tests/onnx_fetch_receipt_tests.py' \
  'linux/scripts/tests/workflow-lane-query.py' \
  'linux/scripts/verify_readme_length.py' 'linux/scripts/verify_image_env.py' \
  'linux/scripts/verify_dead_functions.py' \
  'linux/scripts/verify_code_size.py' \
  'linux/scripts/verify_trailing_conditional.py' \
  'linux/scripts/03-media/build/gstreamer/common/gst-python-build-config.py' \
  'linux/scripts/03-media/runtime/ort-venv-census.py' \
  'linux/scripts/05-frameworks/flutter/fetch-fallback-fonts.py' \
  'linux/scripts/05-frameworks/flutter/check-web-artefacts.py' \
  'linux/llm-stack/tests/gateway_e2e/conftest.py' \
  'linux/llm-stack/tests/gateway_e2e/gw_client.py' \
  'linux/llm-stack/tests/gateway_e2e/test_e2e_ops.py' \
  'linux/llm-stack/tests/gateway_e2e/test_e2e_routing.py' \
  'linux/llm-stack/tests/gateway_e2e/test_e2e_shaping.py' \
  'linux/llm-stack/tests/gateway_e2e/gw_fake_lane.py' \
  'linux/llm-stack/tests/gateway_e2e/gw_harness.py' \
  'linux/scripts/tests/apt-update-selection-tests.py' \
  'linux/scripts/tests/guarded_link_tests.py' \
  'linux/scripts/tests/test-image-acceptance.py' \
  'docs/scripts/bump_versions.py' \
  'linux/webserver/scripts/flutter_capture_console_errors.py' \
  'linux/scripts/tests/header_discovery_tests.py' \
  'linux/scripts/tests/qnn_query_tests.py' \
  'linux/scripts/tests/chain-ort-fixtures.py' \
  'linux/scripts/tests/chain_sibling_pid_tests.py' \
  'linux/scripts/tests/log_dir_consumer_tests.py' \
  'linux/scripts/tests/media-pin-advisory-tests.py' \
  'linux/scripts/tests/directory_visitor_tests.py' \
  'linux/scripts/tests/sudo-policy-tests.py' \
  'linux/scripts/tests/raw_pin_reader_tests.py' \
  'linux/scripts/tests/cross_active_registration_tests.py' \
  'linux/scripts/tests/compiler_candidate_tests.py' \
  'linux/scripts/tests/media_file_set_tests.py' \
  'linux/scripts/tests/smoke-query-contract-tests.py' \
  'linux/scripts/tests/clang_job_policy_tests.py' \
  'linux/scripts/tests/binfmt_probe_tests.py' \
  'linux/scripts/tests/meson_dispatch_tests.py' \
  'linux/scripts/tests/host_cargo_preparation_tests.py' \
  'linux/scripts/tests/target_cargo_pipeline_tests.py' \
  'linux/scripts/tests/host_python_pin_tests.py' \
  'linux/scripts/tests/validator_probe_tests.py' \
  'linux/scripts/tests/runtime_child_stop_tests.py' \
  'linux/scripts/tests/wheel_tag_resolution_tests.py' \
  'linux/scripts/tests/runtime_sdk_help_tests.py' \
  'linux/scripts/tests/triplet_query_tests.py' \
  'linux/scripts/verify_advertised_keys.py' \
  'linux/scripts/tests/cli_help_exit_tests.py' \
  'linux/scripts/tests/image_ref_cli_tests.py' \
  'linux/scripts/tests/smoke_native_dispatch_tests.py' \
  'linux/scripts/tests/nerdctl_service_receipt_tests.py' \
  'linux/scripts/tests/binfmt_probe_controls.py' \
  'linux/scripts/tests/native_gcc_env_tests.py' \
  'linux/scripts/verify_dockerfile_env_order.py' \
  'linux/scripts/tests/test-image-consumer-bootstrap.py' \
  'linux/scripts/tests/npm_python_transport_tests.py' \
  'linux/scripts/tests/python-provider-context-tests.py' \
  'linux/llm-stack/tests/test_serving_stack.py' \
  'linux/llm-stack/tests/conftest.py' \
  'linux/scripts/tests/libcamera-report-tests.py' \
  'linux/scripts/tests/consumer_quality_wiring_tests.py' \
  'linux/scripts/extract_embedded_python.py' \
  'linux/scripts/tests/test-corrosion-toolchain.py' \
  'linux/scripts/tests/sudo_policy_closure_tests.py' \
  'linux/scripts/tests/wheel_archive_transport_tests.py' \
  'linux/scripts/tests/webdav_download_tests.py' \
  'linux/scripts/tests/meson_bound_provider_tests.py' \
  'linux/scripts/05-frameworks/flutter/flutter-trace-summary.py' \
  'linux/scripts/tests/wheelhouse_manifest_tests.py' \
  'linux/scripts/05-frameworks/flutter/frontend-perf-report.py' \
  'linux/scripts/tests/verified_installer_tests.py' \
  'linux/scripts/tests/toolchain_download_loader_tests.py' \
  'linux/scripts/verify_workflow_conventions.py' \
  'linux/scripts/verify_site_links.py' \
  'linux/scripts/quality_allow.py' \
  'linux/scripts/lib/fetch-data-lock.py' \
  'linux/scripts/06-packaging/ort_census_probe.py' \
  'linux/scripts/06-packaging/venv-version-probe.py' \
  'linux/scripts/verify_code_complexity.py' \
  'linux/scripts/verify_gate_registry.py' \
  'linux/scripts/verify_comment_size.py' \
  'linux/scripts/verify_shellcheck_warnings.py' \
  'linux/scripts/gate_scope.py' \
  'linux/scripts/lib/dartdoc-guides.py' \
  'linux/scripts/tests/fleet_dependency_tests.py' \
  'linux/scripts/06-packaging/free-threaded-sysconfig-tools.py' \
  'linux/scripts/image-acceptance.py' 'docs/scripts/verify_mutations.py')
# Runtime imports use their installed package environments in dedicated workflow or image gates.
linux_environment_checked_files=(
  'docs/conf.py'
  'linux/jetson-webcam/app.py'
  'linux/scripts/01-core/download-webdav-files.py'
  'linux/scripts/06-packaging/venv-version-probe.py'
)
windows_environment_checked_files=('windows/scripts/build/litert-wheel-smoke.py')
[ "${#py_files[@]}" -gt 0 ] || { echo "No tracked Python files found" >&2; exit 2; }
[ "${#quality_files[@]}" -gt 0 ] || { echo "No tracked Python quality or test scripts found" >&2; exit 2; }
[ "${#windows_quality_files[@]}" -gt 0 ] || { echo "No tracked Windows Python certificate scripts found" >&2; exit 2; }
[ "${#parameter_return_files[@]}" -eq 122 ] || { echo "Expected 122 tracked parameter and public-return targets, found ${#parameter_return_files[@]}" >&2; exit 2; }
jetson_dockerfile="${ROOT}/linux/Dockerfile.torch"
[ -f "${jetson_dockerfile}" ] || { echo "Torch Dockerfile is missing for the Jetson type gate" >&2; exit 2; }
grep -Fq 'source=linux/jetson-webcam/app.py,target=/tmp/venv-probe-ty/jetson-webcam-app.py,ro' "${jetson_dockerfile}" || {
  echo "Jetson webcam source is not mounted into the torch type gate" >&2
  exit 2
}
grep -Fq 'bash /tmp/venv-probe-ty/check.sh /opt/venv /tmp/venv-probe-ty/jetson-webcam-app.py' "${jetson_dockerfile}" || {
  echo "Jetson webcam source is not checked against the assembled torch venv" >&2
  exit 2
}
for file in "${linux_environment_checked_files[@]}" "${windows_environment_checked_files[@]}"; do
  git ls-files --error-unmatch -- "$file" >/dev/null 2>&1 || {
    echo "Missing separately checked Python source: ${file}" >&2
    exit 2
  }
  [ -f "$file" ] || {
    echo "Separately checked Python source is missing on disk: ${file}" >&2
    exit 2
  }
done

has_environment_type_gate() {
  local file="$1" candidate
  for candidate in "${linux_environment_checked_files[@]}" "${windows_environment_checked_files[@]}"; do
    [ "${file}" = "${candidate}" ] && return 0
  done
  return 1
}

linux_files=()
windows_files=()
for file in "${py_files[@]}"; do
  has_environment_type_gate "${file}" && continue
  if [[ "${file}" == windows/* ]]; then
    windows_files+=("${file}")
  else
    linux_files+=("${file}")
  fi
done

ty=(uvx "ty@${TY_VERSION}" check --python "${quality_python}" --python-version 3.14 --output-format concise)
search=(--extra-search-path docs/scripts --extra-search-path linux/scripts --extra-search-path shared/python)

strict_scan() {
  local label="$1" report="$2" count="$3" rc=0
  shift 3
  "$@" > "${report}" 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if [ -f "${report}" ]; then cat "${report}" >&2; fi
    printf '%s failed (exit %s)\n' "${label}" "${rc}" >&2
    exit "${rc}"
  fi
  printf '%s: clean (%s files); %s\n' "${label}" "${count}" "${report}"
}

if [ "${1:-}" = --docs-conf ]; then
  # Sphinx rendering stays in the docs build; this checks static configuration types only.
  strict_scan "ty docs configuration gate" "${report_dir}/ty-docs-conf-gate.txt" "${#docs_conf_files[@]}" \
    "${ty[@]}" --python-platform linux "${search[@]}" --extra-search-path "${theme}" "${docs_conf_files[@]}"
  exit 0
fi

# Findings remain visible during adoption; setup and checker crashes still fail CI.
report_scan() {
  local label="$1" platform="$2" report="$3" rc=0
  shift 3
  [ "$#" -gt 0 ] || return 0
  "${ty[@]}" --python-platform "${platform}" "${search[@]}" "$@" > "${report}" 2>&1 || rc=$?
  case "${rc}" in
    0) printf '%s: clean (%s files)\n' "${label}" "$#" ;;
    1)
      cat "${report}" >&2
      printf '%s failed (exit 1); %s\n' "${label}" "${report}" >&2
      return 1
      ;;
    *) cat "${report}" >&2; return "${rc}" ;;
  esac
}

annotation_rc=0
uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN001,ANN002,ANN003,ANN201,ANN202,ANN204,ANN205,ANN206 \
  --output-format concise "${py_files[@]}" > "${annotations_report}" 2>&1 || annotation_rc=$?
case "${annotation_rc}" in
  0|1) ;;
  *) cat "${annotations_report}" >&2; exit "${annotation_rc}" ;;
esac

strict_scan "Ruff signature annotation gate" "${annotations_gate_report}" "${#py_files[@]}" \
  uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN002,ANN003,ANN204,ANN205,ANN206 --output-format concise "${py_files[@]}"
strict_scan "Ruff private return gate" "${private_returns_report}" "${#py_files[@]}" \
  uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN202 --output-format concise "${py_files[@]}"
strict_scan "Ruff parameter and public return gate" "${parameter_returns_report}" "${#parameter_return_files[@]}" \
  uvx "ruff@${RUFF_VERSION}" check --no-fix --select ANN001,ANN201 --output-format concise "${parameter_return_files[@]}"
strict_scan "ty quality gate" "${strict_report}" "${#quality_files[@]}" \
  "${ty[@]}" --python-platform linux "${search[@]}" "${quality_files[@]}"
strict_scan "ty Windows gate" "${windows_gate_report}" "${#windows_quality_files[@]}" \
  "${ty[@]}" --python-platform windows "${search[@]}" "${windows_quality_files[@]}"

report_scan "Linux Python report" linux "${linux_report}" "${linux_files[@]}"
report_scan "Windows Python report" windows "${windows_report}" "${windows_files[@]}"

if [ "${annotation_rc}" -eq 1 ]; then
  cat "${annotations_report}" >&2
  printf 'Ruff annotation gate failed (exit 1); %s\n' "${annotations_report}" >&2
  exit 1
fi
printf 'Ruff annotation gate: clean (%s files); %s\n' "${#py_files[@]}" "${annotations_report}"
