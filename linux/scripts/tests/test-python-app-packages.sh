#!/usr/bin/env bash
# A recording uv checks provider substitution and fail-closed ordering, without a real resolver or wheel.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT_DIR="$(cd "${TESTS_DIR}/../06-packaging" && pwd)"
SUBJECT="${SCRIPT_DIR}/python-app-bundle.sh"
t_skip_unless "Python with tomllib" python3 -c 'import tomllib'
eval "$(t_fn_src "${SUBJECT}" install_python_app_packages)" || exit 1

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
cd "${_work}" || exit 1
mkdir calls
cat > uv.lock <<'LOCK'
[[package]]
name = "onnxruntime"
[[package]]
name = "ONNXRuntime_GPU"
[[package]]
name = "onnxruntime-directml"
[[package]]
name = "onnxruntime-openvino"
[[package]]
name = "onnxruntime-genai"
[[package]]
name = "onnxruntime-extensions"
[[package]]
name = "numpy"
[[package]]
name = "flatbuffers"
LOCK

# Separate argument records preserve spaces; the export stub retains provider dependencies and hashes.
uv() {
  local n path="" omitted="" arg
  n="$(find calls -name '*.txt' | wc -l | tr -d ' ')"
  printf '%s\n' "$@" > "calls/${n}.txt"
  if [ "$1" = export ]; then
    [ "${FAIL_AT:-}" != export ] || return 41
    shift
    while [ "$#" -gt 0 ]; do
      arg="$1"; shift
      case "${arg}" in
        --no-emit-package) omitted+=" $1"; shift ;;
        --output-file) path="$1"; shift ;;
      esac
    done
    python3 - "${path}" "${omitted}" <<'PY'
import sys
import tomllib

with open("uv.lock", "rb") as stream:
    packages = tomllib.load(stream)["package"]
omitted = set(sys.argv[2].split())
with open(sys.argv[1], "w") as stream:
    for package in packages:
        name = package["name"].lower().replace("_", "-")
        if name not in omitted:
            stream.write(f"{name}==1.0 --hash=sha256:fixture\n")
PY
  elif [ "${FAIL_AT:-}" = resolve ] && [ "${n}" = 1 ]; then
    return 42
  elif [ "${FAIL_AT:-}" = app ] && [ "${n}" = 2 ]; then
    return 43
  fi
}

_run() {
  rm -f calls/*.txt
  local rc=0
  install_python_app_packages "runtime with spaces/python" "app with spaces.whl" "chain with spaces.whl" "${_work}" app gpu || rc=$?
  printf '%s' "${rc}"
}

t_case "replace only runtime providers before the first resolver transaction"
t_assert_eq 0 "$(_run)" "success"
_export="$(cat calls/0.txt)"
for _provider in onnxruntime onnxruntime-gpu onnxruntime-directml onnxruntime-openvino; do
  t_assert_contains "${_export}" $'--no-emit-package\n'"${_provider}" "${_provider} excluded"
  t_assert_eq "" "$(grep -E "^${_provider}==" requirements.lock.txt || true)" "provider absent from requirements"
done
for _retained in onnxruntime-genai onnxruntime-extensions numpy flatbuffers; do
  t_assert_contains "$(cat requirements.lock.txt)" "${_retained}==1.0 --hash=sha256:fixture" "${_retained} and its hash retained"
done
for _flag in --locked --no-dev --no-emit-project; do
  t_assert_contains "${_export}" "${_flag}" "${_flag} retained"
done
t_assert_contains "${_export}" $'--extra\napp\n--extra\ngpu' "all configured extras retained"
_resolve="$(cat calls/1.txt)"
t_assert_contains "${_resolve}" $'--requirement\n'"${_work}/requirements.lock.txt" "locked dependency file used"
t_assert_contains "${_resolve}" $'chain with spaces.whl' "local chain wheel is in the first resolver transaction"
t_assert_eq "" "$(printf '%s\n' "${_resolve}" | grep -E '^--(no-deps|no-index)$' || true)" "dependencies are resolved, not ignored"
t_assert_contains "$(cat calls/2.txt)" $'--no-deps\napp with spaces.whl' "app follows the resolved packages"
t_assert_eq 3 "$(find calls -name '*.txt' | wc -l | tr -d ' ')" "no later index install, uninstall or fallback"
t_assert_contains "$(cat "${SUBJECT}")" 'install_python_app_packages "${PY}" "${app_wheel}" "${ort_wheel}" "${WORK_DIR}" "${EXTRAS[@]}"' "the real bundle invokes the helper"

t_case "an export failure never reaches the resolver"
FAIL_AT="export"
t_assert_eq 1 "$(_run)" "export failure propagated"
t_assert_eq 1 "$(find calls -name '*.txt' | wc -l | tr -d ' ')" "no install after export failure"

t_case "a resolver failure never installs the app or falls back to PyPI"
FAIL_AT=resolve
t_assert_eq 1 "$(_run)" "resolver failure propagated"
t_assert_eq 2 "$(find calls -name '*.txt' | wc -l | tr -d ' ')" "no install after resolver failure"

t_case "an app install failure remains fatal"
FAIL_AT=app
t_assert_eq 43 "$(_run)" "app status propagated"
unset FAIL_AT

t_case "an unreadable lock fails before any uv call"
mv uv.lock valid.lock
t_assert_eq 1 "$(_run 2>/dev/null)" "lock read failed"
t_assert_eq 0 "$(find calls -name '*.txt' | wc -l | tr -d ' ')" "no partial export or install"

t_summary
