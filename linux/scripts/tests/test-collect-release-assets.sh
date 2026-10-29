#!/usr/bin/env bash
# collect-release-assets.sh over each consumer's uploads and options, and the guards of release-publish.yml. See docs/branch-and-release-strategy.md#collecting-the-release-files
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
COLLECT="${TESTS_DIR}/../06-packaging/collect-release-assets.sh"
WORKFLOW="$(cd "${TESTS_DIR}/../../.." && pwd)/.github/workflows/release-publish.yml"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# collect <log> <args...>: the script with its output in ${work}/<log>.
collect() {
  local log="$1"
  shift
  bash "${COLLECT}" "$@" > "${work}/${log}" 2>&1
}
log() { cat "${work}/$1"; }
count() { find "$1" -maxdepth 1 -type f -name "$2" | wc -l | tr -d ' '; }
# zip_case <name>: a case whose uploads include a folder shipped as a zip.
zip_case() {
  t_case "$1"
  t_needs zip command -v zip
}

t_case "usage: two directories, known options, rules with a value"
t_assert_eq 2 "$(t_rc bash "${COLLECT}" "${work}/only-one")"
t_assert_fails collect usage-1 --frobnicate "${work}/a" "${work}/b"
t_assert_contains "$(log usage-1)" "unknown option --frobnicate"
mkdir -p "${work}/u/up"
printf 'x' > "${work}/u/up/f.deb"
t_assert_fails collect usage-2 --rename '*.deb' "${work}/u" "${work}/u-out"
t_assert_contains "$(log usage-2)" "a rule needs GLOB=VALUE"
t_assert_fails collect usage-3 --include "'*.deb'" "${work}/u" "${work}/u-out2"
t_assert_contains "$(log usage-3)" "write '*.deb' unquoted"
t_assert_fails collect usage-4 "${work}/no-such-dir" "${work}/u-out3"

t_case "names: {version} needs --version, {arch} an arch word in the upload's name"
t_assert_fails collect names-1 --rename '*.deb=app-{version}.deb' "${work}/u" "${work}/n1"
t_assert_contains "$(log names-1)" "pass --version"
t_assert_fails collect names-2 --rename '*.deb=app-{machine}.deb' "${work}/u" "${work}/n2"
t_assert_contains "$(log names-2)" "no arch in 'up'"
mkdir -p "${work}/r/app-linux-riscv64-packages"
printf 'x' > "${work}/r/app-linux-riscv64-packages/app.deb"
t_assert_ok collect names-3 --version 1.2.3 --rename '*.deb=app-{version}-{arch}-{machine}-{stem}.deb' "${work}/r" "${work}/n3"
t_assert_ok test -e "${work}/n3/app-1.2.3-riscv64-riscv64-app.deb"
t_assert_fails collect names-4 --rename '*.deb=sub/{stem}.deb' "${work}/r" "${work}/n4"
t_assert_contains "$(log names-4)" "not a file name"

t_case "options file: one option per line, comments and blank lines skipped, CRLF read"
printf '# the release\r\n\r\n  --include   *.deb  \r\n--version 9.9.9\r\n' > "${work}/crlf.options"
t_assert_ok collect opts-1 --options "${work}/crlf.options" "${work}/u" "${work}/o1"
t_assert_ok test -e "${work}/o1/f.deb"
printf 'include *.deb\n' > "${work}/bad.options"
t_assert_fails collect opts-2 --options "${work}/bad.options" "${work}/u" "${work}/o2"
t_assert_contains "$(log opts-2)" "is not an option"
t_assert_fails collect opts-3 --options "${work}/none.options" "${work}/u" "${work}/o3"

# OmniAccelerANT: named uploads, renamed and zipped, every platform expected.
cat > "${work}/omniaccelerant.options" <<'OPTS'
--strict
--skip build-log*
--skip flutter-build-log-*
--skip *-debug
--skip *-natives-*
--skip gstreamer-ai-web-frontend
--skip *-test-results
--skip *-tests
--include omni-observant-*/*
--include omni-accelerant-installers-windows-*/*
--include omni-accelerant-linux-*-packages/*.deb
--include omni-accelerant-linux-*-packages/*.AppImage
--rename omni-accelerant-linux-*-packages/*.flatpak=omni-accelerant-{version}-{machine}.flatpak
--rename omni-accelerant-linux-*-tar/*.tar.gz=omni-accelerant-{version}-linux-{arch}.tar.gz
--unpack omni-accelerant-apk-*-tar
--rename omni-accelerant-apk-*-tar/*/app-release.apk=omni-accelerant-{version}-android-arm64-v8a.apk
--zip windows-release-files=omni-accelerant-{version}-windows-x64.zip
--zip omni-accelerant-windows-arm64=omni-accelerant-{version}-windows-arm64.zip
--expect omni-accelerant-{version}-windows-x64.zip
--expect omni-accelerant-{version}-windows-arm64.zip
--expect omni-accelerant-{version}-android-arm64-v8a.apk
--expect omni-accelerant_{version}_amd64.deb
--expect omni-accelerant_{version}_arm64.deb
--expect omni-observant_{version}_arm64.deb
--expect omni-observant-{version}-windows-x64.msi
--expect omni-observant-{version}-windows-arm64.msi
--expect omni-accelerant-{version}-windows-x64.msi
--expect omni-accelerant-{version}-windows-arm64.msi
--expect omni-accelerant-{version}-windows-x64.msix
--expect omni-accelerant-{version}-windows-arm64.msix
OPTS

# oa_uploads <dir>: one of each upload an OmniAccelerANT release run makes.
oa_uploads() {
  local a="$1" arch deb ext
  for arch in x64 arm64; do
    deb=amd64
    if [ "$arch" = arm64 ]; then deb=arm64; fi
    mkdir -p "${a}/omni-accelerant-linux-${arch}-packages" "${a}/omni-accelerant-linux-${arch}-tar" "${a}/omni-observant-linux-${arch}"
    printf 'd' > "${a}/omni-accelerant-linux-${arch}-packages/omni-accelerant_2.1.0_${deb}.deb"
    printf 'f' > "${a}/omni-accelerant-linux-${arch}-packages/omni-accelerant-2.1.0.flatpak"
    printf 't' > "${a}/omni-accelerant-linux-${arch}-tar/omni-accelerant-linux-${arch}.tar.gz"
    printf 'o' > "${a}/omni-observant-linux-${arch}/omni-observant_2.1.0_${deb}.deb"
    mkdir -p "${a}/omni-observant-windows-${arch}" "${a}/omni-accelerant-installers-windows-${arch}"
    printf 'm' > "${a}/omni-observant-windows-${arch}/omni-observant-2.1.0-windows-${arch}.msi"
    for ext in .msi .msix -testcert.cer; do printf 'i' > "${a}/omni-accelerant-installers-windows-${arch}/omni-accelerant-2.1.0-windows-${arch}${ext}"; done
  done
  mkdir -p "${a}/omni-accelerant-apk-linux-x64-tar/src/omni-accelerant-apk-bundle" "${a}/windows-release-files/data" \
    "${a}/omni-accelerant-windows-arm64" "${a}/build-log" "${a}/omni-accelerant-natives-windows-arm64" \
    "${a}/omni-accelerant-windows-arm64-debug" "${a}/gstreamer-ai-web-frontend"
  printf 'apk' > "${a}/omni-accelerant-apk-linux-x64-tar/src/omni-accelerant-apk-bundle/app-release.apk"
  tar -czf "${a}/omni-accelerant-apk-linux-x64-tar/omni-accelerant-apk-linux-x64.tar.gz" -C "${a}/omni-accelerant-apk-linux-x64-tar/src" omni-accelerant-apk-bundle
  rm -rf "${a}/omni-accelerant-apk-linux-x64-tar/src"
  printf 'exe' > "${a}/windows-release-files/omni_accelerant.exe"
  printf 'dat' > "${a}/windows-release-files/data/app.so"
  printf 'exe' > "${a}/omni-accelerant-windows-arm64/omni_accelerant.exe"
  printf 'log' > "${a}/build-log/build.log"
  printf 'dll' > "${a}/omni-accelerant-natives-windows-arm64/AccelerANTgine.dll"
  printf 'dbg' > "${a}/omni-accelerant-windows-arm64-debug/omni_accelerant.exe"
  printf 'js' > "${a}/gstreamer-ai-web-frontend/main.dart.js"
  mkdir -p "${a}/docs-site-docs"
  printf 'html' > "${a}/docs-site-docs/index.html"
}
oa() { collect "$1" --options "${work}/omniaccelerant.options" --version 2.1.0 "${work}/$2" "${work}/$3"; }

oa_uploads "${work}/oa"
out="${work}/oa-release"

zip_case "OmniAccelerANT: a full release run's uploads collect, the docs site's upload skipped though strict"
t_assert_ok oa oa-1 oa oa-release

zip_case "OmniAccelerANT: both Windows apps zipped, the x64 zip with its folders"
t_assert_ok test -s "${out}/omni-accelerant-2.1.0-windows-x64.zip"
t_assert_ok test -s "${out}/omni-accelerant-2.1.0-windows-arm64.zip"
t_assert_contains "$(unzip -l "${out}/omni-accelerant-2.1.0-windows-x64.zip" 2>&1)" "data/app.so"

zip_case "OmniAccelerANT: the APK out of its tarball, the tarball itself not shipped"
t_assert_eq apk "$(cat "${out}/omni-accelerant-2.1.0-android-arm64-v8a.apk" 2>&1)"
t_assert_eq 0 "$(count "${out}" 'omni-accelerant-apk-*')"
t_assert_ok test -e "${work}/oa/omni-accelerant-apk-linux-x64-tar/omni-accelerant-apk-linux-x64.tar.gz"

zip_case "OmniAccelerANT: flatpaks and tarballs named with version and arch"
t_assert_ok test -e "${out}/omni-accelerant-2.1.0-x86_64.flatpak"
t_assert_ok test -e "${out}/omni-accelerant-2.1.0-aarch64.flatpak"
t_assert_ok test -e "${out}/omni-accelerant-2.1.0-linux-x64.tar.gz"
t_assert_ok test -e "${out}/omni-accelerant-2.1.0-linux-arm64.tar.gz"

zip_case "OmniAccelerANT: ObservANT packages and the app's installers as they are"
t_assert_ok test -e "${out}/omni-observant_2.1.0_arm64.deb"
t_assert_ok test -e "${out}/omni-observant_2.1.0_amd64.deb"
t_assert_ok test -e "${out}/omni-observant-2.1.0-windows-x64.msi"
t_assert_ok test -e "${out}/omni-observant-2.1.0-windows-arm64.msi"
t_assert_eq 4 "$(count "${out}" 'omni-accelerant-2.1.0-windows-*.ms*')"
t_assert_eq 2 "$(count "${out}" 'omni-accelerant-2.1.0-windows-*-testcert.cer')"

zip_case "OmniAccelerANT: no logs, natives, debug build or web build, and nothing else"
t_assert_eq 0 "$(find "${out}" -name '*log*' -o -name 'AccelerANTgine*' -o -name '*debug*' -o -name '*.dart.js' -o -name '*.exe' | wc -l | tr -d ' ')"
t_assert_eq 19 "$(count "${out}" '*')"

oa_uploads "${work}/oa-b"
mkdir -p "${work}/oa-b/omni-accelerant-macos"

zip_case "OmniAccelerANT: an upload nobody decided about fails the release"
t_assert_fails oa oa-2 oa-b oa-r2
t_assert_contains "$(log oa-2)" "upload omni-accelerant-macos is neither collected nor skipped"

# oa_lacking <log> <upload> <missing release file>: the release fails without that upload, naming the file.
oa_lacking() {
  oa_uploads "${work}/$1"
  rm -rf "${work:?}/$1/$2"
  t_assert_fails oa "$1.log" "$1" "$1-release"
  t_assert_contains "$(log "$1.log")" "the release would lack $3"
}

zip_case "OmniAccelerANT: a release without a platform fails, naming what it lacks"
oa_lacking oa-c omni-accelerant-windows-arm64 omni-accelerant-2.1.0-windows-arm64.zip
oa_lacking oa-e omni-observant-windows-arm64 omni-observant-2.1.0-windows-arm64.msi
oa_lacking oa-f omni-accelerant-installers-windows-arm64 omni-accelerant-2.1.0-windows-arm64.msi

oa_uploads "${work}/oa-d"
mkdir -p "${work}/oa-d/omni-observant-linux-x64-again"
cp "${work}/oa-d/omni-observant-linux-x64/omni-observant_2.1.0_amd64.deb" "${work}/oa-d/omni-observant-linux-x64-again/"

zip_case "OmniAccelerANT: two uploads of one file name fail rather than overwrite"
t_assert_fails oa oa-d.log oa-d oa-d-release
t_assert_contains "$(log oa-d.log)" "two artifacts carry omni-observant_2.1.0_amd64.deb"

# OxidANT: every package by extension, flatpaks by arch, the portable folder zipped.
cat > "${work}/oxidant.options" <<'OPTS'
--include *.msix
--include *.msi
--include *.AppImage
--include *.deb
--include *.tar.gz
--zip kataglyphis_cli-windows-*/bundle=kataglyphis_cli-{version}-windows-{arch}.zip
--flatpak-arch-from-suffix
--skip *-tests
--skip *-test-results
OPTS

ox="${work}/ox"
for arch in x64 arm64; do
  d="${ox}/oxidant-2.3.4-ubuntu-26.04-${arch}-all"
  mkdir -p "${d}/dist" "${d}/target/release"
  printf 'tar' > "${d}/dist/oxidant-2.3.4-linux_${arch}.tar.gz"
  printf 'deb' > "${d}/dist/oxidant_2.3.4_${arch}.deb"
  printf 'img' > "${d}/dist/oxidant-2.3.4-${arch}.AppImage"
  printf 'flatpak' > "${d}/dist/oxidant-2.3.4.flatpak"
  printf 'path' > "${d}/dist/archive_path.txt"
  printf 'elf' > "${d}/target/release/kataglyphis_cli"
  printf 'report' > "${d}/tarpaulin-report.html"
done

w="${ox}/kataglyphis_cli-windows-x64"
mkdir -p "${w}/msix" "${w}/msi" "${w}/bundle/lib" "${ox}/kataglyphis_cli-windows-arm64/bundle" "${ox}/kataglyphis_cli-windows-arm64-tests/msi"
printf 'msix' > "${w}/msix/Kataglyphis.OxidANT_2.3.4.0_x64.msix"
printf 'msi' > "${w}/msi/kataglyphis_cli-2.3.4-x64.msi"
printf 'pdb' > "${w}/msi/kataglyphis_cli-2.3.4-x64.wixpdb"
printf 'exe' > "${w}/bundle/kataglyphis_cli.exe"
printf 'dll' > "${w}/bundle/lib/gst.dll"
printf 'exe' > "${ox}/kataglyphis_cli-windows-arm64/bundle/kataglyphis_cli.exe"
printf 'msi' > "${ox}/kataglyphis_cli-windows-arm64-tests/msi/tests.msi"

ox_run() { collect "$1" --options "${work}/oxidant.options" --version 2.3.4 "$2" "$3"; }
out="${work}/ox-release"

zip_case "OxidANT: it collects every Linux package of both arches, the MSI and the MSIX"
t_assert_ok ox_run ox-1 "${ox}" "${out}"
t_assert_eq 2 "$(count "${out}" '*.tar.gz')"
t_assert_eq 2 "$(count "${out}" '*.deb')"
t_assert_eq 2 "$(count "${out}" '*.AppImage')"
t_assert_ok test -e "${out}/kataglyphis_cli-2.3.4-x64.msi"
t_assert_ok test -e "${out}/Kataglyphis.OxidANT_2.3.4.0_x64.msix"

zip_case "OxidANT: each flatpak named for its arch"
t_assert_ok test -e "${out}/oxidant-2.3.4-x86_64.flatpak"
t_assert_ok test -e "${out}/oxidant-2.3.4-aarch64.flatpak"

zip_case "OxidANT: the portable Windows folder, zipped with its subfolders"
t_assert_ok bash -c "unzip -Z1 '${out}/kataglyphis_cli-2.3.4-windows-x64.zip' | grep -qx 'lib/gst.dll'"
t_assert_ok test -e "${out}/kataglyphis_cli-2.3.4-windows-arm64.zip"

zip_case "OxidANT: no reports, loose binaries, wix symbols, path notes or test artifact"
t_assert_eq 12 "$(count "${out}" '*')"
t_assert_fails test -e "${out}/tests.msi"

zip_case "OxidANT: relative paths, as the workflow passes them"
t_assert_ok bash -c "cd '${work}' && bash '${COLLECT}' --options oxidant.options --version 2.3.4 ox ox-relative >/dev/null 2>&1"
t_assert_ok test -e "${work}/ox-relative/kataglyphis_cli-2.3.4-windows-x64.zip"
t_assert_ok test -e "${work}/ox-relative/kataglyphis_cli-2.3.4-windows-arm64.zip"

zip_case "OxidANT: a Windows upload without its bundle folder fails"
mkdir -p "${work}/ox-nobundle/kataglyphis_cli-windows-x64/msi"
printf 'msi' > "${work}/ox-nobundle/kataglyphis_cli-windows-x64/msi/a.msi"
t_assert_fails ox_run ox-2 "${work}/ox-nobundle" "${work}/ox-r2"
t_assert_contains "$(log ox-2)" "upload kataglyphis_cli-windows-x64 has no bundle to zip"

zip_case "OxidANT: two artifacts with one file name fail; no packages at all fail"
mkdir -p "${ox}/kataglyphis_cli-msi-copy"
cp "${w}/msi/kataglyphis_cli-2.3.4-x64.msi" "${ox}/kataglyphis_cli-msi-copy/"
t_assert_fails ox_run ox-3 "${ox}" "${work}/ox-r3"
t_assert_contains "$(log ox-3)" "two artifacts carry kataglyphis_cli-2.3.4-x64.msi"
mkdir -p "${work}/none/x"
t_assert_fails ox_run ox-4 "${work}/none" "${work}/ox-r4"
t_assert_contains "$(log ox-4)" "no packages under"

zip_case "zip: two folders zipped under one name fail rather than merge"
mkdir -p "${work}/zz/app-windows-x64" "${work}/zz/app-windows-arm64"
printf 'a' > "${work}/zz/app-windows-x64/a.exe"
printf 'b' > "${work}/zz/app-windows-arm64/b.exe"
t_assert_fails collect zz-1 --zip '*-windows-*=app.zip' "${work}/zz" "${work}/zz-release"
t_assert_contains "$(log zz-1)" "two artifacts carry app.zip"

# AccelerANTgine and BeschleunigerBallett: CPack's packages, not the bundle they zip.
cat > "${work}/cpack.options" <<'OPTS'
--skip *-tests
--skip *-test-results
--exclude */bundle/*
--include *.deb
--include *.AppImage
--include *.tar.gz
--include *.tgz
--include *.msi
--include *.msix
--include *.zip
--include *.exe
--flatpak-arch-from-suffix
OPTS
cp "${work}/cpack.options" "${work}/accelerantgine.options"
printf -- '--include *.whl\n' >> "${work}/accelerantgine.options"

# cpack_uploads <dir> <project> <package prefix> <windows upload>: the CMake projects' uploads.
cpack_uploads() {
  local a="$1" p="$3" pair arch m l w ext site
  for pair in x64:x86_64 arm64:aarch64; do
    arch="${pair%%:*}" m="${pair##*:}"
    l="${a}/linux-packages-${arch}"
    mkdir -p "${l}" "${a}/python-wheels-${arch}/gil" "${a}/python-wheels-${arch}/free-threaded"
    for ext in deb tar.gz AppImage; do printf 'pkg' > "${l}/${p}-Linux-${m}-Release-Clang-23.1.3.${ext}"; done
    printf 'flatpak' > "${l}/${p}-linux.flatpak"
    printf 'whl' > "${a}/python-wheels-${arch}/gil/kataglyphis_inference-0.0.1-cp314-cp314-linux_${m}.whl"
    printf 'whl' > "${a}/python-wheels-${arch}/free-threaded/kataglyphis_inference-0.0.1-cp314-cp314t-linux_${m}.whl"
    w="${a}/$4-${arch}"
    mkdir -p "${w}/packages" "${w}/msix" "${w}/bundle/bin" "${w}/bundle/lib"
    for ext in msi zip; do printf 'pkg' > "${w}/packages/${p}-Windows-${m}-Release-Clang-23.1.3.${ext}"; done
    printf 'msix' > "${w}/msix/$2_${arch}.msix"
    printf 'exe' > "${w}/bundle/bin/$2.exe"
    printf 'zip' > "${w}/bundle/lib/runtime.zip"
  done
  printf 'nsis' > "${a}/$4-x64/packages/${p}-Windows-x86_64-Release-Clang-23.1.3.exe"
  mkdir -p "${a}/$4-arm64-tests/packages"
  printf 'msi' > "${a}/$4-arm64-tests/packages/tests.msi"
  for site in "${2,,}-docs-site" docs-site-docs; do
    mkdir -p "${a}/${site}/_downloads"
    printf 'zip' > "${a}/${site}/_downloads/examples.zip"
  done
}
# cpack_cases <repo> <options> <project> <package prefix> <windows upload> <wheels>: the cases both repos share.
cpack_cases() {
  local a="${work}/$1" out="${work}/$1-release" p="$4"
  cpack_uploads "${a}" "$3" "${p}" "$5"
  t_case "$1: it collects the Linux packages of both arches"
  t_assert_ok collect "$1-1" --options "${work}/$2" "${a}" "${out}"
  t_assert_eq 6 "$(count "${out}" "${p}-Linux-*")"
  t_case "$1: each flatpak named for its arch"
  t_assert_ok test -e "${out}/${p}-linux-x86_64.flatpak"
  t_assert_ok test -e "${out}/${p}-linux-aarch64.flatpak"
  t_case "$1: the MSI, zip and MSIX of both Windows arches"
  t_assert_eq 6 "$(find "${out}" -maxdepth 1 \( -name '*.msi' -o -name '*.msix' -o -name '*.zip' \) | wc -l | tr -d ' ')"
  t_case "$1: the x64 installer, but nothing from a bundle or a test artifact"
  t_assert_ok test -e "${out}/${p}-Windows-x86_64-Release-Clang-23.1.3.exe"
  t_assert_fails test -e "${out}/$3.exe"
  t_assert_fails test -e "${out}/runtime.zip"
  t_assert_fails test -e "${out}/tests.msi"
  t_case "$1: nothing from either upload of the docs site"
  t_assert_fails test -e "${out}/examples.zip"
  t_case "$1: the wheels, gil and free-threaded, only where asked for"
  t_assert_eq "$6" "$(count "${out}" '*.whl')"
  t_case "$1: relative paths, as the workflow passes them"
  t_assert_ok bash -c "cd '${work}' && bash '${COLLECT}' --options '$2' '$1' '$1-relative' >/dev/null 2>&1"
  t_assert_ok test -e "${work}/$1-relative/$3_arm64.msix"
  t_case "$1: two artifacts with one file name fail rather than overwrite"
  mkdir -p "${a}/$5-x64-copy/packages"
  cp "${a}/$5-x64/packages/${p}-Windows-x86_64-Release-Clang-23.1.3.msi" "${a}/$5-x64-copy/packages/"
  t_assert_fails collect "$1-2" --options "${work}/$2" "${a}" "${work}/$1-r2"
  t_assert_contains "$(log "$1-2")" "two artifacts carry"
}
cpack_cases AccelerANTgine accelerantgine.options AccelerANTgine AccelerANTgine-0.0.1 AccelerANTgine-windows 4
cpack_cases BeschleunigerBallett cpack.options GraphicsEngine GraphicsEngine-1.5.0 BeschleunigerBallett-windows 0

# OrchestrANT: whatever the packagers wrote under packages/.
cat > "${work}/orchestrant.options" <<'OPTS'
--include */packages/*
--skip test-reports-*
--skip *-tests
--skip *-test-results
OPTS

a="${work}/orch"
v=0.0.31
for pair in x64:x86_64:amd64 arm64:aarch64:arm64; do
  arch="${pair%%:*}" rest="${pair#*:}"
  m="${rest%%:*}" deb="${rest##*:}"
  l="${a}/packages-linux-${arch}-source-and-binary"
  mkdir -p "${l}/dist/packages" "${a}/test-reports-${arch}/packages"
  printf 'img' > "${l}/dist/packages/orchestrant-${v}-${m}.AppImage"
  printf 'tar' > "${l}/dist/packages/orchestrant-${v}-linux-${m}.tar.gz"
  printf 'deb' > "${l}/dist/packages/orchestrant_${v}_${deb}.deb"
  printf 'whl' > "${l}/dist/orchestrant-${v}-cp315-cp315-manylinux_${m}.whl"
  printf 'xml' > "${a}/test-reports-${arch}/packages/report.xml"
done

# orch_windows <packages dir> <arch>: the MSI, MSIX, zip and test certificate of one Windows arch.
orch_windows() {
  local ext
  mkdir -p "$1"
  for ext in .msi .msix .zip -test-signing.cer; do printf '%s' "$2" > "$1/orchestrant-${v}-windows-$2${ext}"; done
}
w="${a}/python-package-windows-source-and-binaries"
x="${a}/orchestrant-windows-arm64"
orch_windows "${w}/dist/packages" x64
orch_windows "${x}/packages" arm64
mkdir -p "${w}/logs" "${x}/bundle/runtime" "${a}/orchestrant-windows-arm64-tests/packages" "${a}/packages-linux-riscv64-source-and-binary/dist"
printf 'whl' > "${w}/dist/orchestrant-${v}-cp315-cp315-win_amd64.whl"
printf 'log' > "${w}/logs/build.log"
printf 'exe' > "${x}/bundle/runtime/python.exe"
printf 'msi' > "${a}/orchestrant-windows-arm64-tests/packages/tests.msi"
printf 'whl' > "${a}/packages-linux-riscv64-source-and-binary/dist/orchestrant-${v}-cp315-cp315-linux_riscv64.whl"

out="${work}/orch-release"

t_case "OrchestrANT: the 14 packages of the last tag release, and nothing else"
t_assert_ok collect orch-1 --options "${work}/orchestrant.options" "${a}" "${out}"
t_assert_eq 14 "$(count "${out}" '*')"
t_assert_ok test -e "${out}/orchestrant_${v}_amd64.deb"
t_assert_ok test -e "${out}/orchestrant-${v}-linux-aarch64.tar.gz"
t_assert_ok test -e "${out}/orchestrant-${v}-windows-arm64.msix"
t_assert_ok test -e "${out}/orchestrant-${v}-windows-x64-test-signing.cer"
t_assert_eq 0 "$(find "${out}" -name '*.whl' -o -name 'python.exe' -o -name 'report*' -o -name 'tests.msi' | wc -l | tr -d ' ')"

t_case "OrchestrANT: two artifacts with one file name fail rather than overwrite"
mkdir -p "${a}/orchestrant-windows-arm64-copy/packages"
cp "${x}/packages/orchestrant-${v}-windows-arm64.msi" "${a}/orchestrant-windows-arm64-copy/packages/"
t_assert_fails collect orch-2 --options "${work}/orchestrant.options" "${a}" "${work}/orch-r2"
t_assert_contains "$(log orch-2)" "two artifacts carry orchestrant-${v}-windows-arm64.msi"

# WebDavClient: wheels and the sdist; the pure wheel and the sdist from Linux x64 only.
cat > "${work}/webdavclient.options" <<'OPTS'
--skip test-reports-*
--include *.whl
--include *.tar.gz
--exclude */docs/*
--exclude */logs/*
--only-from *-py3-none-any.whl=packages-linux-x64-*
--only-from *.tar.gz=packages-linux-x64-*
OPTS

a="${work}/wdc"
p=kataglyphis_webdavclient-0.0.1
for pair in x64:x86_64 arm64:aarch64; do
  arch="${pair%%:*}" m="${pair##*:}" d="${a}/packages-linux-${pair%%:*}-source-and-binary"
  mkdir -p "${d}" "${a}/test-reports-${arch}"
  for abi in cp314-cp314 cp314-cp314t; do printf '%s' "${arch}" > "${d}/${p}-${abi}-manylinux2014_${m}.manylinux_2_17_${m}.whl"; done
  printf '%s' "${arch}" > "${d}/${p}-py3-none-any.whl"
  printf '%s' "${arch}" > "${d}/${p}.tar.gz"
  printf 'whl' > "${a}/test-reports-${arch}/${p}-py3-none-any.whl"
done

w="${a}/python-package-windows-source-and-binaries"
mkdir -p "${w}/dist" "${w}/logs/test-results" "${a}/packages-windows-arm64-wheels"
for abi in cp314-cp314 cp314-cp314t; do printf 'win' > "${w}/dist/${p}-${abi}-win_amd64.whl"; done
printf 'win' > "${w}/dist/${p}-py3-none-any.whl"
printf 'win' > "${w}/dist/${p}.tar.gz"
printf 'cov' > "${w}/logs/test-results/coverage.tar.gz"
printf 'log' > "${w}/logs/build-windows.whl"
for abi in cp314-cp314 cp314-cp314t; do printf 'arm' > "${a}/packages-windows-arm64-wheels/${p}-${abi}-win_arm64.whl"; done

out="${work}/wdc-release"

t_case "WebDavClient: it collects, though all three lanes carry the pure wheel and the sdist"
t_assert_ok collect wdc-1 --options "${work}/webdavclient.options" "${a}" "${out}"
t_assert_eq 8 "$(count "${out}" '*-cp314-*.whl')"

t_case "WebDavClient: one pure wheel and one sdist, Linux x64's"
t_assert_eq x64x64 "$(cat "${out}/${p}-py3-none-any.whl" "${out}/${p}.tar.gz" 2>&1)"

t_case "WebDavClient: ten files and nothing else: no report, coverage or log"
t_assert_eq 10 "$(count "${out}" '*')"

t_case "WebDavClient: two artifacts with one binary wheel fail rather than overwrite"
mkdir -p "${a}/packages-linux-x64-copy"
cp "${w}/dist/${p}-cp314-cp314-win_amd64.whl" "${a}/packages-linux-x64-copy/"
t_assert_fails collect wdc-2 --options "${work}/webdavclient.options" "${a}" "${work}/wdc-r2"
t_assert_contains "$(log wdc-2)" "two artifacts carry ${p}-cp314-cp314-win_amd64.whl"

# DocumANTation: one upload, which download-artifact extracts without its folder.
cat > "${work}/documantation.options" <<'OPTS'
--include *.whl
--include *.tar.gz
--expect sphinx_kataglyphis_theme-{version}-py3-none-any.whl
--expect sphinx_kataglyphis_theme-{version}.tar.gz
OPTS

a="${work}/doc-flat"
mkdir -p "${a}"
printf 'whl' > "${a}/sphinx_kataglyphis_theme-0.1.0-py3-none-any.whl"
printf 'sdist' > "${a}/sphinx_kataglyphis_theme-0.1.0.tar.gz"
doc() { collect "$1" --options "${work}/documantation.options" --version 0.1.0 "${@:2}"; }

t_case "DocumANTation: a lone upload extracted without its folder is collected under its name"
t_assert_ok doc doc-1 --lone-upload theme-dist "${a}" "${work}/doc-r1"
t_assert_eq 2 "$(count "${work}/doc-r1" '*')"

t_case "DocumANTation: files outside any upload fail without --lone-upload rather than vanish"
t_assert_fails doc doc-2 "${a}" "${work}/doc-r2"
t_assert_contains "$(log doc-2)" "files lie directly in ${a}, outside any upload"

t_case "DocumANTation: --lone-upload reads the upload's folder when the download kept it"
mkdir -p "${work}/doc-nested/theme-dist"
cp "${a}"/* "${work}/doc-nested/theme-dist/"
t_assert_ok doc doc-3 --lone-upload theme-dist "${work}/doc-nested" "${work}/doc-r3"
t_assert_eq 2 "$(count "${work}/doc-r3" '*')"

t_case "DocumANTation: a lone upload that matches --skip gives nothing"
t_assert_fails doc doc-4 --lone-upload theme-dist --skip 'theme-*' "${a}" "${work}/doc-r4"

# _job <name>: the lines of one job of the workflow, from its key to the next job's; a CRLF checkout's \r is dropped.
_job() { awk -v job="  $1:" '{ sub(/\r$/, "") } $0 == job { on = 1; next } on && /^  [a-z-]+:$/ { exit } on' "${WORKFLOW}"; }

t_case "release-publish.yml: the check job reads, the publish job writes, a stage typo fails"
check="$(_job check)"
publish="$(_job publish)"
t_assert_contains "${check}" "if: inputs.stage != 'publish'"
t_assert_contains "${check}" "contents: read"
t_assert_contains "${check}" '[ "${STAGE}" = check ] ||'
t_assert_contains "${publish}" "if: inputs.stage == 'publish'"
t_assert_contains "${publish}" "contents: write"

t_case "release-publish.yml: only a dry run passes a failed version check, and it never publishes"
t_assert_contains "${check}" '[ "${DRY_RUN}" = true ] || exit 1'
t_assert_contains "${publish}" "if: \${{ !inputs.dry-run }}"
t_assert_contains "${publish}" "publish-github-release.sh"
t_assert_contains "${publish}" '[ "${GITHUB_REF}" = refs/heads/main ] ||'
t_assert_contains "${publish}" "collect-release-assets.sh"
t_assert_contains "${publish}" 'lone=(--lone-upload "${ARTIFACTS}")'
t_assert_eq 0 "$(grep -c 'continue-on-error' "${WORKFLOW}")" "a release step that may fail is a release that silently stops"

t_summary
