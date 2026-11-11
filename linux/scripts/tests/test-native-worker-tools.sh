#!/usr/bin/env bash
# Fake tools/archive and YAML wiring checks prove no actual SDK download, hosted CI execution or GPU behavior.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
source "${TESTS_DIR}/lib-contract-fixture.sh"
declare work ROOT out rc
t_fixture_workspace_init work ROOT || exit 1
lc_init "${work}" || exit 1
for tool in cc c++ rustc sccache; do lc_stub "${tool}"; done
scripts="${work}/scripts"
mkdir -p "${scripts}/lib" "${scripts}/01-core" "${scripts}/05-frameworks/flutter" "${work}/payload/flutter/bin/cache/dart-sdk/bin"
cp "${ROOT}/linux/scripts/ensure-native-worker-test-tools.sh" "${scripts}/"
cp "${ROOT}/linux/scripts/lib/cli-value-options.sh" "${ROOT}/linux/scripts/lib/log-bootstrap.sh" "${scripts}/lib/"
cp "${ROOT}/linux/scripts/01-core/download-loader.sh" "${scripts}/01-core/"
cp "${ROOT}/linux/scripts/05-frameworks/flutter/setup-flutter.sh" "${scripts}/05-frameworks/flutter/"
cat > "${scripts}/05-frameworks/flutter/flutter-pin.sh" <<'PIN'
flutter_resolve_pin() {
  [[ -z "${FLUTTER_VERSION:-}${FLUTTER_SDK_SHA256:-}" ]] || return 42
  export FLUTTER_VERSION=0.0.0 FLUTTER_SDK_SHA256="${FIXTURE_ARCHIVE_SHA}"
}
PIN
printf '{"frameworkVersion":"0.0.0"}\n' > "${work}/payload/flutter/bin/cache/flutter.version.json"
printf '#!/usr/bin/env bash\nexit "${FIXTURE_DART_STATUS:-0}"\n' > "${work}/payload/flutter/bin/cache/dart-sdk/bin/dart"
chmod +x "${work}/payload/flutter/bin/cache/dart-sdk/bin/dart"
tar -cJf "${work}/flutter.tar.xz" -C "${work}/payload" flutter
cat > "${work}/download-env.sh" <<'DOWNLOAD'
download_and_extract() { return 99; }
download_verified_file() {
  printf '%s|%s\n' "$1" "$2" >> "${FIXTURE_FETCH_LOG}"
  [[ "$2" == "${FIXTURE_ARCHIVE_SHA}" ]] || return 48
  [[ "${FIXTURE_FETCH_STATUS:-0}" == 0 ]] || return "${FIXTURE_FETCH_STATUS}"
  cp "${FIXTURE_ARCHIVE}" "$3"
}
DOWNLOAD
export FIXTURE_ARCHIVE="${work}/flutter.tar.xz"
FIXTURE_ARCHIVE_SHA="$(sha256sum "${FIXTURE_ARCHIVE}" | cut -d ' ' -f1)" || exit 1
export FIXTURE_ARCHIVE_SHA
export FIXTURE_FETCH_LOG="${work}/fetch.log"

t_case 'pinned SDK retention ignores inherited overrides and runs the extracted Dart'
t_capture_command out rc env PATH="${work}/bin:${PATH}" BASH_ENV="${work}/download-env.sh" \
  FLUTTER_VERSION=stale FLUTTER_SDK_SHA256=stale bash "${scripts}/ensure-native-worker-test-tools.sh" "${work}/kept"
printf '%s\n' "${out}"
t_assert_eq 0 "${rc}"
t_assert_contains "$(cat "${FIXTURE_FETCH_LOG}")" "|${FIXTURE_ARCHIVE_SHA}"
t_assert_contains "$(lc_argv)" 'sccache --version'
t_assert_contains "$(lc_argv)" 'rustc --version'
t_assert_eq yes "$(test -x "${work}/kept/flutter/bin/cache/dart-sdk/bin/dart" && echo yes)"

t_case 'a matching SDK repeats without fetching'
: > "${FIXTURE_FETCH_LOG}"
t_capture_command out rc env PATH="${work}/bin:${PATH}" BASH_ENV="${work}/download-env.sh" \
  bash "${scripts}/ensure-native-worker-test-tools.sh" "${work}/kept"
printf '%s\n' "${out}"
t_assert_eq 0 "${rc}"
t_assert_eq '' "$(cat "${FIXTURE_FETCH_LOG}")"

t_case 'the default image installer still strips the Dart cache'
t_capture_command out rc env BASH_ENV="${work}/download-env.sh" FLUTTER_SDK_SHA256="${FIXTURE_ARCHIVE_SHA}" \
  bash "${scripts}/05-frameworks/flutter/setup-flutter.sh" --arch x64 --version 0.0.0 --dir "${work}/bare"
printf '%s\n' "${out}"
t_assert_eq 0 "${rc}"
t_assert_eq absent "$(test -e "${work}/bare/flutter/bin/cache" && echo present || echo absent)"

t_case 'a half-resolved pin cannot reach the SDK installer even with an existing runtime'
cp "${scripts}/05-frameworks/flutter/setup-flutter.sh" "${work}/real-setup.sh"
printf '#!/usr/bin/env bash\necho PIN-INSTALLER-CALLED\n' > "${scripts}/05-frameworks/flutter/setup-flutter.sh"
t_capture_command out rc env PATH="${work}/bin:${PATH}" BASH_ENV="${work}/download-env.sh" FIXTURE_ARCHIVE_SHA= \
  bash "${scripts}/ensure-native-worker-test-tools.sh" "${work}/kept"
mv "${work}/real-setup.sh" "${scripts}/05-frameworks/flutter/setup-flutter.sh"
printf '%s\n' "${out}" > "${work}/empty-pin.log"
t_assert_eq 1 "${rc}"
t_assert_no_grep "${work}/empty-pin.log" PIN-INSTALLER-CALLED

t_case 'each failed prerequisite retains its raw status before fetching'
for tool in cc c++ rustc sccache; do
  lc_fail "${tool}" 47
  : > "${FIXTURE_FETCH_LOG}"
  t_capture_command out rc env PATH="${work}/bin:${PATH}" BASH_ENV="${work}/download-env.sh" \
    bash "${scripts}/ensure-native-worker-test-tools.sh" "${work}/missing-${tool}"
  t_assert_eq 47 "${rc}" "${tool} failure"
  t_assert_eq '' "$(cat "${FIXTURE_FETCH_LOG}")"
  lc_pass "${tool}"
done

t_case 'download and Dart execution failures remain fatal'
t_capture_command out rc env PATH="${work}/bin:${PATH}" BASH_ENV="${work}/download-env.sh" FIXTURE_FETCH_STATUS=61 \
  bash "${scripts}/ensure-native-worker-test-tools.sh" "${work}/fetch-failure"
t_assert_eq 61 "${rc}"
t_capture_command out rc env PATH="${work}/bin:${PATH}" BASH_ENV="${work}/download-env.sh" FIXTURE_DART_STATUS=62 \
  bash "${scripts}/ensure-native-worker-test-tools.sh" "${work}/dart-failure"
t_assert_eq 62 "${rc}"

t_case 'both source-CI jobs and isolated bootstrap require the same provisioner before tests'
t_capture_command out rc python3 - "${ROOT}" <<'PYTEST'
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
workflow = yaml.safe_load((root / '.github/workflows/linux-x64.yml').read_text())
for name in ('preflight', 'mutations'):
    steps = workflow['jobs'][name]['steps']
    setup = [i for i, s in enumerate(steps) if s.get('uses') == './.github/actions/native-worker-test-tools']
    tests = [i for i, s in enumerate(steps) if 'bash linux/scripts/preflight.sh' in s.get('run', '')]
    assert len(setup) == len(tests) == 1 and setup[0] < tests[0], name
    assert any(s.get('name') == 'Ensure PE icon test tools' for s in steps[:setup[0]])
action = yaml.safe_load((root / '.github/actions/native-worker-test-tools/action.yml').read_text())
steps = action['runs']['steps']
assert any(s.get('with', {}).get('key') == 'native-worker-sdk-${{ runner.os }}-${{ runner.arch }}-${{ steps.pin.outputs.sha256 }}' for s in steps)
runs = '\n'.join(s.get('run', '') for s in steps)
assert 'flutter_resolve_pin' in runs and 'FLUTTER_SDK_SHA256:?' in runs
assert 'sccache build-essential xz-utils' in runs
assert 'bash linux/scripts/ensure-native-worker-test-tools.sh' in runs
assert '${GITHUB_PATH}' in runs and '/flutter/bin/cache/dart-sdk/bin' in runs
bootstrap = (root / 'linux/scripts/isolated-preflight/bootstrap.sh').read_text()
required = 'bash "${task_source}/linux/scripts/ensure-native-worker-test-tools.sh" /opt/preflight-native-tools'
assert bootstrap.count(required) == 1 and bootstrap.index(required) < bootstrap.index('exec setpriv')
assert 'nodejs npm sccache ' in bootstrap
assert 'PATH=/opt/preflight-native-tools/flutter/bin/cache/dart-sdk/bin:' in bootstrap
print('All native-worker prerequisite consumers checked')
PYTEST
printf '%s\n' "${out}"
t_assert_eq 0 "${rc}"
t_summary
