#!/usr/bin/env bash
# Reuse the production loader and keep its exact extracted body with the native probe evidence.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ]; then
  printf 'Usage: bash linux/scripts/probe-ort-plugin.sh <migraphx|tensorrt|qnn> <evidence-directory>\n'
  exit 0
fi
[ "$#" -eq 2 ] || { printf 'provider and evidence directory are required\n' >&2; exit 2; }
provider="$1"
evidence="$2"
case "${provider}" in
  migraphx) root_var=ORT_AMDGPU_EP_ROOT; module=libmigraphx-ep.so ;;
  tensorrt) root_var=ORT_TENSORRT_EP_ROOT; module=libonnxruntime_ep_tensorrt.so ;;
  qnn) root_var=ORT_QNN_EP_ROOT; module=libonnxruntime_providers_qnn.so ;;
  *) printf 'unknown plugin provider: %s\n' "${provider}" >&2; exit 2 ;;
esac
source "${SCRIPT_DIR}/01-core/python-probe.sh"
ci_image_python_require plugin-native-probe docs/linux-accelerator-images.md /usr/local/bin/python3
mkdir -p "${evidence}"
evidence="$(cd "${evidence}" && pwd)"
work="$(mktemp -d)"
report() {
  "${PREFLIGHT_PYTHON}" -I - "${evidence}" "${SCRIPT_DIR}" "${provider}" "${root_var}" "${module}" "$1" <<'PY'
import datetime
import hashlib
import json
import os
import sys
from pathlib import Path

evidence, scripts, provider, root_var, module, status = sys.argv[1:]
def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


root = os.environ.get(root_var)
library = Path(root, "lib", module) if root else None
paths = {"probe": Path(scripts, "probe-ort-plugin.sh"),
         "production": Path(scripts, "03-media/runtime/assemble-torch-app.sh"),
         "extracted_function": Path(evidence, "verify-function.sh")}
record = {"status": "running" if status == "running" else ("passed-native-load-only" if status == "0" else "failed"),
          "exit_code": None if status == "running" else int(status), "provider": provider,
          "root_variable": root_var, "root": root, "module": module,
          "observed_at": datetime.datetime.now(datetime.UTC).isoformat(),
          "source_sha256": {key: digest(path) for key, path in paths.items() if path.is_file()},
          "module_sha256": digest(library) if library and library.is_file() else None,
          "coverage_limits": ["Native library load and factory exports only.", "No EP registration, GPU inference, wrapper or consumer acceptance proof."]}
Path(evidence, "evidence.json").write_text(json.dumps(record, indent=2) + "\n")
PY
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if ! "${PREFLIGHT_PYTHON}" -I -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "${work}"; then
    [ "${status}" -ne 0 ] || status=1
  fi
  report "${status}" || status=1
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
function_source="$(bash -c 'source "$1"; t_fn_src "$2" verify_ort_plugin_library' bash \
  "${SCRIPT_DIR}/tests/test-harness.sh" "${SCRIPT_DIR}/03-media/runtime/assemble-torch-app.sh")"
printf '%s\n' "${function_source}" > "${evidence}/verify-function.sh"
source "${evidence}/verify-function.sh"
report running
uv venv "${work}/venv" --python "${PREFLIGHT_PYTHON}"
export VIRTUAL_ENV="${work}/venv"
verify_ort_plugin_library "${root_var}" "${module}"
