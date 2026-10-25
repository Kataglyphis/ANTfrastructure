#!/usr/bin/env bash
# A real pinned ty fixture proves the build gate resolves venv imports and rejects type errors; shipped-library behavior remains in image smokes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"

t_case "the torch Dockerfile checks both probes against the assembled venv"
type_run="$(awk '/^RUN --mount=type=bind,source=linux\/scripts\/06-packaging\/check-venv-probe-types.sh,/{on=1} on {print} on && /^    esac/ {exit}' "${S}/../Dockerfile.torch")"
t_assert_contains "${type_run}" 'load-ty-tool.sh,target=/tmp/venv-probe-ty/load-ty-tool.sh' \
  "the shared pin loader must be mounted beside the build-time checker"
t_assert_contains "${type_run}" 'source=linux/jetson-webcam/app.py,target=/tmp/venv-probe-ty/jetson-webcam-app.py,ro' \
  "the Jetson app source must be mounted only into the type-check step"
actual="$(printf '%s\n' "${type_run}" | grep -E '^[[:space:]]*amd64\)' || true)"
t_assert_contains "${actual}" 'bash /tmp/venv-probe-ty/check.sh /opt/venv /opt/scripts/packaging/venv-version-probe.py /tmp/venv-probe-ty/tool-pins.env &&' \
  "the x64 build must check the packaged probe against its assembled environment"
t_assert_contains "${type_run}" 'bash /tmp/venv-probe-ty/check.sh /opt/venv /tmp/venv-probe-ty/jetson-webcam-app.py /tmp/venv-probe-ty/tool-pins.env ;;' \
  "the same runtime environment must type-check the Jetson app"
t_assert_contains "$(cat "${S}/../Dockerfile.package")" \
  'COPY --chmod=644 linux/scripts/06-packaging/venv-version-probe.py /opt/scripts/packaging/venv-version-probe.py' \
  "the source passed to ty must be packaged at that path"

ROOT="$(mktemp -d)"
trap 'rm -rf -- "${ROOT}"' EXIT

mkdir -p "${ROOT}/gate"
cp "${S}/06-packaging/check-venv-probe-types.sh" "${ROOT}/gate/check.sh"
cp "${S}/01-core/load-versions-env.sh" "${ROOT}/gate/"
cp "${S}/01-core/load-ty-tool.sh" "${ROOT}/gate/"
sed -n '/^TY_VERSION=/p' "${S}/01-core/tool-pins.env" > "${ROOT}/gate/tool-pins.env"
command -v uv >/dev/null 2>&1 || { echo "uv is required for the venv probe type fixture" >&2; exit 2; }
uv venv --offline --python "$(command -v python3)" "${ROOT}/venv" >/dev/null 2>&1 || exit 2
site="$("${ROOT}/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
mkdir -p "${site}/runtime_only"
printf 'VALUE: int = 42\n' > "${site}/runtime_only/__init__.py"
printf 'from runtime_only import VALUE\n\ndef answer() -> int:\n    return VALUE\n' > "${ROOT}/probe.py"

_check() {
  local output rc=0
  output="$(bash "${ROOT}/gate/check.sh" "${ROOT}/venv" "${ROOT}/probe.py" "${ROOT}/gate/tool-pins.env" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${output}" "${rc}"
}

t_case "the pinned ty gate resolves imports from the assembled venv"
out="$(_check)"
t_assert_contains "${out}" "All checks passed!"
t_assert_contains "${out}" "rc=0"

t_case "an ambient ty version cannot replace the repository pin"
out="$(TY_VERSION=0.0.0 _check)"
t_assert_contains "${out}" "All checks passed!"
t_assert_contains "${out}" "rc=0"

t_case "an unresolved venv-only import fails instead of passing on exit status alone"
rm "${site}/runtime_only/__init__.py"
out="$(_check)"
t_assert_contains "${out}" "unresolved-import"
t_assert_contains "${out}" "rc=1"
printf 'VALUE: int = 42\n' > "${site}/runtime_only/__init__.py"

t_case "a return-type mutation fails the same strict gate"
printf 'from runtime_only import VALUE\n\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/probe.py"
out="$(_check)"
t_assert_contains "${out}" "invalid-return-type"
t_assert_contains "${out}" "rc=1"

t_case "a missing probe fails before invoking ty"
rm "${ROOT}/probe.py"
out="$(_check)"
t_assert_contains "${out}" "missing source"
t_assert_contains "${out}" "rc=2"

t_summary
