#!/usr/bin/env bash
# Stubbed sdkmanager proves retries and verdicts; no downloads, apt, real SDK or delay runs here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_source_functions "${TESTS_DIR}/../02-toolchain/android-sdk.sh" sdkmanager_retry accept_licenses sdkmanager_install || exit 1
D="$(mktemp -d)"
trap 'rm -rf "${D}"' EXIT
export ANDROID_HOME="${D}/sdk with spaces" SDK_CALLS="${D}/calls" SDK_SLEEPS="${D}/sleeps"
cat > "${D}/sdkmanager" <<'STUB'
#!/usr/bin/env bash
count=0
[ ! -f "${SDK_CALLS}" ] || count="$(wc -l < "${SDK_CALLS}")"
printf '<%s>' "$@" >> "${SDK_CALLS}"
printf '\n' >> "${SDK_CALLS}"
if [ "$((count + 1))" -lt "${SUCCEED_ON:-1}" ]; then
  printf 'Done.\n'
  exit 7
fi
printf '%s\n' "${SDK_OUTPUT:-All SDK package licenses accepted}"
exit "${SDK_STATUS:-0}"
STUB
chmod +x "${D}/sdkmanager"
export sdkmanager_bin="${D}/sdkmanager"
sleep() { printf '%s\n' "$1" >> "${SDK_SLEEPS}"; }
_reset() { : > "${SDK_CALLS}"; : > "${SDK_SLEEPS}"; }
_reset
t_case "licenses require confirmation even on exit zero"
t_assert_eq 1 "$(SDK_OUTPUT=Done. t_rc accept_licenses)"
t_assert_eq 6 "$(wc -l < "${SDK_CALLS}")"
t_assert_eq $'3\n3\n3\n3\n3' "$(cat "${SDK_SLEEPS}")"
t_assert_ok test -d "${ANDROID_HOME}/licenses"
_reset
t_case "confirmation accepts licenses despite nonzero exit"
t_assert_eq 0 "$(SDK_STATUS=9 t_rc accept_licenses)"
t_assert_eq 1 "$(wc -l < "${SDK_CALLS}")"
_reset
t_case "installation trusts status rather than a Done message"
t_assert_eq 1 "$(SUCCEED_ON=99 t_rc sdkmanager_install 'platforms;android-35' 'a package with spaces')"
t_assert_eq 4 "$(wc -l < "${SDK_CALLS}")"
t_assert_eq $'5\n5\n5' "$(cat "${SDK_SLEEPS}")"
t_assert_contains "$(head -1 "${SDK_CALLS}")" "<--sdk_root=${ANDROID_HOME}><platforms;android-35><a package with spaces>"
_reset
t_case "transient install failures stop at the first successful exit"
t_assert_eq 0 "$(SUCCEED_ON=3 SDK_OUTPUT=Installed t_rc sdkmanager_install 'package%name')"
t_assert_eq 3 "$(wc -l < "${SDK_CALLS}")"
t_assert_eq $'5\n5' "$(cat "${SDK_SLEEPS}")"
_reset
t_case "transient license failures retain their separate retry policy"
t_assert_eq 0 "$(SUCCEED_ON=2 t_rc accept_licenses)"
t_assert_eq 2 "$(wc -l < "${SDK_CALLS}")"
t_assert_eq 3 "$(cat "${SDK_SLEEPS}")"
t_case "unknown retry modes fail without invoking sdkmanager"
_reset
t_assert_eq 2 "$(t_rc sdkmanager_retry other)"
t_assert_eq 0 "$(wc -l < "${SDK_CALLS}")"
t_summary
