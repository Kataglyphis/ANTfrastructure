#!/usr/bin/env bash
# gstreamer-bundle.sh: copy takes the plugins a package names and nothing else; check fails on an element the package cannot load.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

GSB="${TESTS_DIR}/../06-packaging/gstreamer-bundle.sh"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

mkdir -p "${_work}/image" "${_work}/camera"
for p in coreelements videoconvertscale autodetect; do printf '%s' "${p}" > "${_work}/image/libgst${p}.so"; done
printf 'camera' > "${_work}/camera/libgstlibcamera.so"
ln -s libgstcoreelements.so "${_work}/image/libgstlink.so"
_copy() { bash "${GSB}" copy --dest "${_work}/$1" --plugin-dir "${_work}/image" --plugin-dir "${_work}/camera" "${@:2}"; }

t_case "copy: the named plugins from every plugin dir, symlinks resolved, nothing else"
t_assert_ok _copy out1 --plugin coreelements --plugin libcamera --plugin link
t_assert_eq "coreelements" "$(cat "${_work}/out1/libgstcoreelements.so")" "a plugin from the image dir"
t_assert_eq "camera" "$(cat "${_work}/out1/libgstlibcamera.so")" "one from the second dir"
t_assert_fails test -L "${_work}/out1/libgstlink.so"
t_assert_fails test -e "${_work}/out1/libgstautodetect.so"

t_case "copy: a missing required plugin fails, a missing optional one does not"
t_assert_fails _copy out2 --plugin coreelements --plugin videotestsrc
t_assert_ok _copy out3 --plugin coreelements --optional videotestsrc
t_assert_fails test -e "${_work}/out3/libgstvideotestsrc.so"

# Answers like gst-inspect-1.0 for STUB_ELEMENTS from STUB_DIR, and only under a package's plugin environment.
cat > "${_work}/gst-inspect" <<'STUB'
#!/usr/bin/env bash
[ "${GST_PLUGIN_SYSTEM_PATH-unset}" = "" ] && [ "${GST_PLUGIN_SYSTEM_PATH_1_0-unset}" = "" ] || exit 3
[ -z "${GST_PLUGIN_PATH_1_0+x}" ] || exit 3
case " ${STUB_ELEMENTS} " in *" $1 "*) ;; *) exit 255 ;; esac
printf 'Plugin Details:\n  Filename                 %s/libgststub.so\n' "${STUB_DIR:-${GST_PLUGIN_PATH}}"
STUB
chmod +x "${_work}/gst-inspect"
_check() { env GST_INSPECT="${_work}/gst-inspect" "$@" bash "${GSB}" check --plugins "${_work}/out1" videoconvert fdsink; }

t_case "check: every element from the package passes, whatever plugin paths the caller had"
t_assert_ok _check STUB_ELEMENTS="videoconvert fdsink" GST_PLUGIN_SYSTEM_PATH=/usr/lib GST_PLUGIN_PATH_1_0=/usr/lib

t_case "check: an element no bundled plugin provides fails, and is named"
t_assert_fails _check STUB_ELEMENTS="videoconvert"
t_assert_contains "$(_check STUB_ELEMENTS="videoconvert" 2>&1)" "FAIL fdsink" "the missing element is named"

t_case "check: an element loaded from outside the package fails"
t_assert_fails _check STUB_ELEMENTS="videoconvert fdsink" STUB_DIR=/usr/lib/gstreamer-1.0

t_case "check: no plugin directory, or no element, is a usage error"
t_assert_fails bash "${GSB}" check --plugins "${_work}/none" fdsink
t_assert_fails bash "${GSB}" check --plugins "${_work}/out1"

t_summary
