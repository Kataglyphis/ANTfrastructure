#!/usr/bin/env bash
# Offline extracted caller blocks cover diagnostics and lazy probes, not package installation or target Python execution.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
repo="${1:-$(cd "${TESTS_DIR}/../../.." && pwd)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$repo" "$work" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
preamble = (root/'linux/scripts/01-core/install-deps-preamble.sh').read_text()
marker = 'report_cross_python_development() {'
helper = preamble[preamble.index(marker):] if marker in preamble else ''
for name in ('gstreamer', 'litert', 'opencv'):
    text = (root/f'linux/scripts/03-media/build/{name}/install-deps.sh').read_text()
    needle = 'report_cross_python_development' if 'report_cross_python_development' in text else 'cross_target_python_dev_ready'
    line = text.index(needle)
    if name == 'opencv':
        start = text.rfind('if [ "${WITH_PYTHON}"', 0, line)
        end = text.index('\nif [ "${WITH_JAVA}"', line)
    else:
        start = text.rfind('if is_cross; then', 0, line)
        end = text.index('\nfi', line) + 3
    (out/f'{name}.sh').write_text(helper+'\n'+text[start:end]+'\n')
PY
for component in gstreamer litert opencv; do
  for mode in native ready missing absent failed-host empty-version pin disabled; do
    if [ "$mode" = disabled ] && [ "$component" != opencv ]; then continue; fi
    t_case "$component $mode retains diagnostic bytes and probe order"
    actual="$(bash -eu -s -- "$work/$component.sh" "$work/probes" "$mode" <<'BASH'
file=$1; probes=$2; mode=$3
: > "$probes"
is_cross() { [ "$mode" != native ]; }
cross_target_python_dev_ready() { printf 'ready\n' >> "$probes"; [ "$mode" = ready ]; }
cross_target_python_include_dir() { printf 'include\n' >> "$probes"; printf '/stage path/include'; }
host_python_major_minor() { printf 'host\n' >> "$probes"; [ "$mode" != failed-host ] || return 7; printf 3.42; }
cross_target_triplet() { printf 'triplet\n' >> "$probes"; [ "$mode" != failed-host ] || return 8; printf fixture-triplet; }
[ "$mode" != absent ] || unset -f cross_target_python_dev_ready
WITH_PYTHON=true
[ "$mode" != disabled ] || WITH_PYTHON=false
OPENCV_PYTHON_VERSION=3.41
[ "$mode" != empty-version ] || OPENCV_PYTHON_VERSION=''
[ "$mode" != pin ] || PYTHON_MAJOR_MINOR=3.43
source "$file"
BASH
)"
    prefix=''; warning=''; suffix='disabling gst-python'
    if [ "$component" != gstreamer ]; then prefix='[INFO] '; warning='[WARN] '; fi
    [ "$component" != litert ] || suffix='skipping LiteRT Python wheel support'
    [ "$component" != opencv ] || suffix='disabling OpenCV Python bindings'
    expected=''; order=''
    if [ "$mode" = disabled ]; then
      :
    elif [ "$mode" = native ]; then
      [ "$component" != opencv ] || expected='[INFO] Python dependencies are satisfied via source build and uv.'
    elif [ "$mode" = ready ]; then
      expected="${prefix}Using staged target Python headers from /stage path/include"
      order=$'ready\ninclude'
    else
      version=3.42; triplet=fixture-triplet
      [ "$mode" != pin ] || version=3.43
      [ "$mode" != failed-host ] || { version=unknown; triplet=target; }
      if [ "$component" = opencv ]; then version=3.41; [ "$mode" != empty-version ] || version=''; fi
      expected="${warning}Target Python ${version} development files are missing for ${triplet}; ${suffix} for this cross build"
      [ "$mode" = absent ] || order=ready
      if [ "$component" != opencv ] && [ "$mode" != pin ]; then order="${order:+$order$'\n'}host"; fi
      order="${order:+$order$'\n'}triplet"
    fi
    t_assert_eq "$expected" "$actual"
    t_assert_eq "$order" "$(cat "$work/probes")"
  done
done
python3 - "$repo" "$work" <<'PYCODE'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
text = (root/'linux/scripts/03-media/build/gstreamer/common/pre-setup.sh').read_text()
helper = ''
if '_gstreamer_write_pkgconfig() {' in text:
    start = text.index('_gstreamer_write_pkgconfig() {')
    helper = text[start:text.index('\n}', start)+2]+'\n'
for name in ('vulkan', 'csound'):
    end = text.index(f'> "${{pcdir}}/{name}.pc"') if name == 'vulkan' else text.index('> "$pcdir/csound.pc"')
    needle = '  _gstreamer_write_pkgconfig' if helper else "  printf '%s\\n'"
    start = text.rfind(needle, 0, end)
    end = text.index('\n', end)
    (out/f'{name}-pc.sh').write_text(helper+text[start:end]+'\n')
PYCODE
for name in vulkan csound; do
  t_case "$name pkg-config bytes and write-error policy"
  mkdir -p "$work/metadata/$name"
  bash -eu -s -- "$work/$name-pc.sh" "$work/metadata/$name" <<'BASH'
file=$1; pcdir=$2
libdir='/usr/lib/fixture-triplet'; target_libdir=$libdir
sdk_dir='/SDK with spaces/1.2.3/host'; sdk_version=1.2.3
source "$file"
BASH
  description='Vulkan loader using toolchain SDK headers'; version=1.2.3; library=vulkan
  title=Vulkan; include='/SDK with spaces/1.2.3/host/include'
  if [ "$name" = csound ]; then description='Csound audio and music processing system'; version=6.18.1; library=csound64; title=Csound; include=/usr/include/csound; fi
  expected="$(printf '%s\n' 'prefix=/usr' 'exec_prefix=${prefix}' 'libdir=/usr/lib/fixture-triplet' "includedir=$include" '' "Name: $title" "Description: $description" "Version: $version" "Libs: -L\${libdir} -l$library" 'Cflags: -I${includedir}')"
  printf '%s\n' "$expected" > "$work/expected.pc"
  t_assert_eq 0 "$(t_rc cmp "$work/expected.pc" "$work/metadata/$name/$name.pc")"
  rc=0
  bash -eu -s -- "$work/$name-pc.sh" "$work/missing/dir" 2>/dev/null <<'BASH' || rc=$?
file=$1; pcdir=$2
libdir=/usr/lib; target_libdir=$libdir; sdk_dir=/sdk; sdk_version=1
source "$file"
BASH
  expected_rc=1; [ "$name" != csound ] || expected_rc=0
  t_assert_eq "$expected_rc" "$rc"
done
t_case 'optional Vulkan import keeps missing/success/failure and parent environment visibility'
python3 - "$repo" "$work" <<'PYCODE'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
text = (root/'linux/scripts/03-media/build/gstreamer/install-deps.sh').read_text()
if '\nmedia_load_vulkan_toolchain\n' in text:
    common = (root/'linux/scripts/03-media/core/common.sh').read_text()
    start = common.index('media_load_vulkan_toolchain() {')
    code = common[start:common.index('\n}', start)+2]+'\nmedia_load_vulkan_toolchain\n'
else:
    start = text.index('if [ -f /opt/scripts/toolchain/vulkan.sh ]; then')
    code = text[start:text.index('\nfi', start)+3]
(out/'import.sh').write_text(code.replace('/opt/scripts/toolchain/vulkan.sh', str(out/'vulkan.sh')))
PYCODE
t_assert_eq 0 "$(t_rc bash -eu "$work/import.sh")"
printf 'VULKAN_IMPORT=visible\n' > "$work/vulkan.sh"
t_assert_eq visible "$(bash -eu -c 'source "$1"; printf %s "$VULKAN_IMPORT"' _ "$work/import.sh")"
printf 'return 9\n' > "$work/vulkan.sh"
t_assert_eq 9 "$(t_rc bash -eu "$work/import.sh")"
t_case 'SDK selection keeps source side effects, failed-source fallback and pinned/latest precedence'
# shellcheck disable=SC1090
source <(t_fn_src "$repo/linux/scripts/03-media/build/gstreamer/common/pre-setup.sh" find_toolchain_vulkan_sdk_dir)
uname() { printf fixture-arch; }
vulkan_prefix="$work/sdk"
mkdir -p "$vulkan_prefix/1/fixture-arch" "$vulkan_prefix/2/fixture-arch" "$work/preloaded SDK"
export VULKAN_VERSION=1
unset VULKAN_SDK
t_assert_eq "$vulkan_prefix/1/fixture-arch" "$(find_toolchain_vulkan_sdk_dir)"
VULKAN_VERSION=missing
t_assert_eq "$vulkan_prefix/2/fixture-arch" "$(find_toolchain_vulkan_sdk_dir)"
VULKAN_SDK="$work/preloaded SDK"
t_assert_eq "$VULKAN_SDK" "$(find_toolchain_vulkan_sdk_dir)"
source_vulkan_sdk_env() { VULKAN_SDK="$vulkan_prefix/1/fixture-arch"; return 7; }
t_assert_eq "$vulkan_prefix/1/fixture-arch" "$(find_toolchain_vulkan_sdk_dir)"
source_vulkan_sdk_env() { VULKAN_SDK="$vulkan_prefix/2/fixture-arch"; }
t_assert_eq "$vulkan_prefix/2/fixture-arch" "$(find_toolchain_vulkan_sdk_dir)"
unset -f source_vulkan_sdk_env
VULKAN_SDK="$work/missing"; vulkan_prefix="$work/absent"
t_assert_eq 1 "$(t_rc find_toolchain_vulkan_sdk_dir)"
t_summary
