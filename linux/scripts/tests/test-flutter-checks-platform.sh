#!/usr/bin/env bash
# flutter_checks.sh --test-platform: Chrome where the image ships it, the VM otherwise. See docs/consumer-image-contract.md#browser-tests-run-in-chrome-for-testing
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CHECKS="$(cd "${TESTS_DIR}/.." && pwd)/05-frameworks/flutter/flutter_checks.sh"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# Stub flutter and dart that only record their arguments, so the gate's own logic is all that runs.
mkdir -p "${_WORK}/bin"
for tool in flutter dart; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "%s/calls.log"\n' "${tool}" "${_WORK}" > "${_WORK}/bin/${tool}"
  chmod +x "${_WORK}/bin/${tool}"
done

_PKG="${_WORK}/pkg"
mkdir -p "${_PKG}/lib"
printf 'name: fixture\nflutter:\n  uses-material-design: true\n' > "${_PKG}/pubspec.yaml"
printf 'void main() {}\n' > "${_PKG}/lib/main.dart"
git -C "${_PKG}" init -q
t_git_commit "${_PKG}"

# _checks <CHROME_EXECUTABLE value> <args...>: runs the gate in the fixture, prints its rc, then the recorded test call.
_checks() {
  local chrome="$1" rc=0; shift
  rm -f "${_WORK}/calls.log"
  (cd "${_PKG}" && PATH="${_WORK}/bin:${PATH}" CHROME_EXECUTABLE="${chrome}" bash "${CHECKS}" "$@") >/dev/null 2>&1 || rc=$?
  printf '%s|%s' "${rc}" "$(grep '^flutter test' "${_WORK}/calls.log" 2>/dev/null)"
}

t_case "default: the VM, whatever the image ships"
t_assert_eq "0|flutter test" "$(_checks /usr/local/bin/chrome)"

t_case "chrome with a browser in the image"
t_assert_eq "0|flutter test --platform chrome" "$(_checks /usr/local/bin/chrome --test-platform chrome)"

t_case "chrome without one (riscv64): the VM, never zero tests"
t_assert_eq "0|flutter test" "$(_checks '' --test-platform chrome)"

t_case "an unknown platform is refused before anything runs"
t_assert_eq "1|" "$(_checks /usr/local/bin/chrome --test-platform firefox)"

t_summary
