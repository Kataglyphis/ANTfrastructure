#!/usr/bin/env bash
# Stubbed builders check real launcher selection and AppRun dispatch, not compression, installation or GPU execution.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${1:-${TESTS_DIR}/../lib/app-packaging.sh}"
# shellcheck source=../lib/app-packaging.sh
source "$LIB"
work="$(t_mktemp -d)"
mkdir -p "$work/bundle" "$work/out"
cat > "$work/bundle/oxidant" <<'PROGRAM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ENTRYPOINT_TRACE"
exit 47
PROGRAM
printf '#!/usr/bin/env bash\nexit 52\n' > "$work/bundle/aaa-helper"
chmod +x "$work/bundle/oxidant" "$work/bundle/aaa-helper"
export ENTRYPOINT_TRACE="$work/argv" APP_PACKAGING_BINARY_NAME=oxidant

t_case 'the declared CLI wins over an alphabetically earlier native helper'
t_assert_eq oxidant "$(app_packaging_detect_bundle_binary "$work/bundle")"

t_case 'an absent or empty selection retains the existing automatic policy'
t_assert_eq aaa-helper "$(APP_PACKAGING_BINARY_NAME='' app_packaging_detect_bundle_binary "$work/bundle")"

t_case 'a declared path cannot escape the bundle even when its target is executable'
cp "$work/bundle/oxidant" "$work/outside"
for selected in ../outside /outside . .. sub/oxidant; do
    t_assert_eq 1 "$(t_rc env APP_PACKAGING_BINARY_NAME="$selected" bash -c 'source "$1"; app_packaging_detect_bundle_binary "$2"' _ "$LIB" "$work/bundle")"
done

t_case 'missing, nonexecutable and directory selections refuse without falling back'
cp "$work/bundle/oxidant" "$work/bundle/not-executable"
chmod -x "$work/bundle/not-executable"
mkdir "$work/bundle/directory"
for selected in missing not-executable directory; do
    t_assert_eq 1 "$(t_rc env APP_PACKAGING_BINARY_NAME="$selected" bash -c 'source "$1"; app_packaging_detect_bundle_binary "$2"' _ "$LIB" "$work/bundle")"
done

t_case 'declared symlinks refuse without falling back'
t_needs 'real POSIX symlinks for the declared executable fixture' t_posix_symlinks
ln -s oxidant "$work/bundle/link"
t_assert_eq 1 "$(t_rc env APP_PACKAGING_BINARY_NAME=link bash -c 'source "$1"; app_packaging_detect_bundle_binary "$2"' _ "$LIB" "$work/bundle")"

t_case 'real shared renderers route DEB and AppImage launchers to the selected CLI'
export APP_PACKAGING_BUNDLE_DIR="$work/bundle" APP_PACKAGING_VERSION=1.0
export APP_PACKAGING_OUT_DIR="$work/out" KATAGLYPHIS_PACKAGING_WORKDIR="$work/stage"
export APP_PACKAGING_ICON_FILE="$work/icon.png" APP_PACKAGING_DESKTOP_FILE=''
t_write_png "$APP_PACKAGING_ICON_FILE" 2 3
app_packaging_resolve_appimagetool() { printf '%s\n' "$work/appimagetool"; }
app_packaging_appimage_runtime_file() { printf ''; }
dpkg-deb() { printf 'stub deb\n' > "${!#}"; }
cat > "$work/appimagetool" <<'TOOL'
#!/usr/bin/env bash
printf 'stub appimage\n' > "${!#}"
TOOL
chmod +x "$work/appimagetool"
app_packaging_package_linux_bundle_deb x64 oxidant > "$work/deb.log"
t_assert_contains "$(cat "$work/stage/deb/usr/bin/oxidant")" 'exec /opt/oxidant/oxidant "$@"'
app_packaging_package_linux_bundle_appimage x64 oxidant > "$work/appimage.log"
t_assert_eq 47 "$(t_rc bash "$work/stage/oxidant.AppDir/AppRun" --fixture 'two words' '' literal)"
t_assert_eq $'--fixture\ntwo words\n\nliteral' "$(cat "$ENTRYPOINT_TRACE")"
t_assert_ok test -s "$work/out/oxidant_1.0_amd64.deb"
t_assert_ok test -s "$work/out/oxidant-1.0-x86_64.AppImage"

t_case 'copied packaging libraries require the selection companion and its export'
mkdir "$work/copied"
cp "$LIB" "${LIB%/*}/app-packaging-license.sh" "${LIB%/*}/log-bootstrap.sh" "$work/copied/"
rc=0
bash -c 'source "$1" || exit "$?"' _ "$work/copied/app-packaging.sh" > "$work/missing-output" 2>&1 || rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$(cat "$work/missing-output")" app-packaging-entrypoint.sh
printf ':\n' > "$work/copied/app-packaging-entrypoint.sh"
rc=0
bash -c 'source "$1" || exit "$?"' _ "$work/copied/app-packaging.sh" > "$work/empty-output" 2>&1 || rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$(cat "$work/empty-output")" 'lacks app_packaging_detect_bundle_binary'

t_summary
