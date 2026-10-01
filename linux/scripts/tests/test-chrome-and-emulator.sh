#!/usr/bin/env bash
# CON50's browser and emulator: pins, both installers on fixture zips behind a fake curl, the AVD helper and the image wiring.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
CFT="${SCRIPTS}/06-packaging/install-chrome-for-testing.sh"
EMU="${SCRIPTS}/06-packaging/install-android-emulator.sh"
AVD="${SCRIPTS}/04-runtime/android-avd.sh"
VENV="${SCRIPTS}/01-core/versions.env"
PKGF="${SCRIPTS}/../Dockerfile.package"
TORCHF="${SCRIPTS}/../Dockerfile.torch"

_W="$(mktemp -d)"
trap 'rm -rf "${_W}"' EXIT
_pin() { sed -n "s/^$1=//p" "${VENV}" | head -1; }

t_case "every pin the installers read is in versions.env, each checksum a sha256"
for _k in CHROME_FOR_TESTING_VERSION ANDROID_EMULATOR_VERSION ANDROID_EMULATOR_BUILD ANDROID_EMULATOR_API \
          ANDROID_EMULATOR_SYSIMG_REVISION; do
  t_assert_eq 1 "$(_pin "${_k}" | grep -c .)" "${_k} is pinned"
done
for _k in CHROME_FOR_TESTING_LINUX64_SHA256 CHROME_FOR_TESTING_LINUX_ARM64_SHA256 CHROMEDRIVER_LINUX64_SHA256 \
          CHROMEDRIVER_LINUX_ARM64_SHA256 ANDROID_EMULATOR_SHA256 ANDROID_EMULATOR_SYSIMG_SHA256; do
  t_assert_eq 1 "$(_pin "${_k}" | grep -cxE '[0-9a-f]{64}')" "${_k} is a sha256"
done

t_case "the system image is one whose translator runs arm64 apps"
# API 30's ndk_translation 0.2.2 dies on scalar FCVTZU in OmniAccelerANT's APK (measured 2026-10-01).
t_assert_ok test "$(_pin ANDROID_EMULATOR_API)" -ge 35

# A fake curl serves ${_FIX}/<basename of the URL>, so the real download_file and checksum path run.
_FIX="${_W}/fixtures"
mkdir -p "${_W}/fakebin" "${_FIX}"
cat > "${_W}/fakebin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
printf '%s\n' "${url}" >> "${FIX}/requested"
[ -f "${FIX}/${url##*/}" ] || exit 22
cp "${FIX}/${url##*/}" "${out}"
EOF
chmod +x "${_W}/fakebin/curl"
# A host without unzip (WSL here) gets a zipfile stand-in that keeps exec bits; images and CI runners have the real one.
if ! command -v unzip >/dev/null 2>&1; then
  cat > "${_W}/fakebin/unzip" <<'EOF'
#!/usr/bin/env python3
import os, sys, zipfile
args = [a for a in sys.argv[1:] if a != "-q"]
dest = args[args.index("-d") + 1] if "-d" in args else "."
with zipfile.ZipFile(args[0]) as z:
    for i in z.infolist():
        path = z.extract(i, dest)
        if (i.external_attr >> 16) & 0o777:
            os.chmod(path, (i.external_attr >> 16) & 0o777)
EOF
  chmod +x "${_W}/fakebin/unzip"
fi

# _zip <zip> <dir>: zips <dir> (relative to its parent) the way upstream does.
_zip() { (cd "$(dirname "$2")" && python3 -c 'import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for root, _, files in os.walk(sys.argv[2]):
    for f in files:
        p = os.path.join(root, f)
        i = zipfile.ZipInfo(p); i.external_attr = (os.stat(p).st_mode & 0o777) << 16
        z.writestr(i, open(p, "rb").read())' "$1" "$(basename "$2")"); }
_sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- Chrome for Testing ---
_CV=154.0.8037.92
_cft_fixture() {
  local plat="$1" ver="${2:-${_CV}}" render="${3:-yes}" d
  d="${_W}/src-${plat}"
  rm -rf "${d}"; mkdir -p "${d}/chrome-${plat}" "${d}/chromedriver-${plat}"
  cat > "${d}/chrome-${plat}/chrome" <<EOF
#!/bin/sh
case "\$*" in
  *--version*) echo "Google Chrome for Testing ${ver} " ;;
  *--no-sandbox*--dump-dom*) [ "${render}" = yes ] && echo "<html><body>cft-42</body></html>" ;;
esac
exit 0
EOF
  printf '#!/bin/sh\necho "ChromeDriver %s (deadbeef)"\n' "${ver}" > "${d}/chromedriver-${plat}/chromedriver"
  chmod +x "${d}/chrome-${plat}/chrome" "${d}/chromedriver-${plat}/chromedriver"
  rm -f "${_FIX}/chrome-${plat}.zip" "${_FIX}/chromedriver-${plat}.zip"
  _zip "${_FIX}/chrome-${plat}.zip" "${d}/chrome-${plat}"
  _zip "${_FIX}/chromedriver-${plat}.zip" "${d}/chromedriver-${plat}"
}
_cft_env() {
  printf 'CHROME_FOR_TESTING_VERSION=%s\n' "${_CV}"
  printf 'CHROME_FOR_TESTING_LINUX64_SHA256=%s\n' "$(_sha "${_FIX}/chrome-linux64.zip")"
  printf 'CHROMEDRIVER_LINUX64_SHA256=%s\n' "$(_sha "${_FIX}/chromedriver-linux64.zip")"
}
# _run <installer> <VAR=value...>: it runs with only the fake curl's PATH; prints its output, then RC=<n>.
_run() {
  local script="$1" rc=0 out
  shift
  out="$(env -i PATH="${_W}/fakebin:/usr/bin:/bin" HOME="${_W}" FIX="${_FIX}" "$@" bash "${script}" 2>&1)" || rc=$?
  printf '%s\nRC=%s\n' "${out}" "${rc}"
}
# _cft_run <arch> [cache dir]
_cft_run() {
  _run "${CFT}" CFT_ARCH="$1" CFT_SKIP_APT=1 CFT_PREFIX="${_W}/cft" CFT_BIN_DIR="${_W}/cft-bin" \
    VERSIONS_ENV="${_W}/cft.env" TEST_RUNTIMES_CACHE_DIR="${2:-}"
}

t_case "an amd64 install verifies both zips, writes a --no-sandbox wrapper and renders headless"
_cft_fixture linux64
_cft_env > "${_W}/cft.env"
_OUT="$(_cft_run amd64)"
t_assert_contains "${_OUT}" "RC=0"
t_assert_contains "${_OUT}" "OK: Chrome for Testing ${_CV}"
_EXEC="$(grep -e '^exec ' "${_W}/cft-bin/chrome")"
t_assert_contains "${_EXEC}" " --no-sandbox " "uid 1001 in a container has no sandbox to start"
t_assert_contains "${_EXEC}" " --no-zygote " "qemu-user kills the zygote's children with SIGTRAP"
t_assert_eq "${_W}/cft/chromedriver/chromedriver" "$(readlink "${_W}/cft-bin/chromedriver")"
t_assert_contains "$(cat "${_FIX}/requested")" \
  "https://storage.googleapis.com/chrome-for-testing-public/${_CV}/linux64/chrome-linux64.zip" "Google's own bucket"

t_case "a zip whose checksum is off the pin installs nothing (mutation)"
rm -rf "${_W:?}/cft" "${_W}/cft-bin"
_ZERO="$(printf '%064d' 0)"
sed -i "s/^CHROMEDRIVER_LINUX64_SHA256=.*/CHROMEDRIVER_LINUX64_SHA256=${_ZERO}/" "${_W}/cft.env"
_OUT="$(_cft_run amd64)"
t_assert_contains "${_OUT}" "Checksum verification FAILED"
t_assert_fails test "$(printf '%s' "${_OUT}" | tail -1)" = "RC=0"
t_assert_fails test -e "${_W}/cft-bin/chrome"

t_case "a browser off the pin, or one that renders nothing, fails the install (mutation)"
_cft_fixture linux64 153.0.1.1; _cft_env > "${_W}/cft.env"
t_assert_contains "$(_cft_run amd64)" "pin is ${_CV}"
_cft_fixture linux64 "${_CV}" no; _cft_env > "${_W}/cft.env"
t_assert_contains "$(_cft_run amd64)" "headless chrome rendered no page"

t_case "arm64 takes the linux-arm64 zips and their own keys"
t_assert_eq "linux-arm64" "$(bash -c "source '${CFT}'; cft_platform arm64")"
t_assert_eq "CHROMEDRIVER_LINUX_ARM64_SHA256" "$(bash -c "source '${CFT}'; cft_sha_key chromedriver linux-arm64")"
t_assert_contains "$(bash -c "source '${CFT}'; cft_url ${_CV} linux-arm64 chrome")" "/${_CV}/linux-arm64/chrome-linux-arm64.zip"

t_case "riscv64 records why it has no browser and installs nothing"
rm -rf "${_W:?}/cft" "${_W}/cft-bin"
_OUT="$(_cft_run riscv64)"
t_assert_contains "${_OUT}" "RC=0"
t_assert_contains "$(cat "${_W}/cft/.chrome-off")" "reason=Chrome for Testing publishes linux64 and linux-arm64 builds only"
t_assert_fails test -e "${_W}/cft-bin/chrome"

t_case "a cached zip is reused only after it re-verifies"
_cft_fixture linux64; _cft_env > "${_W}/cft.env"
mkdir -p "${_W}/cache"
t_assert_contains "$(_cft_run amd64 "${_W}/cache")" "RC=0"
_CACHED="${_W}/cache/$(_sha "${_FIX}/chrome-linux64.zip")-chrome-linux64.zip"
t_assert_ok test -f "${_CACHED}"
mv "${_FIX}/chrome-linux64.zip" "${_W}/held.zip"
_OUT="$(_cft_run amd64 "${_W}/cache")"
t_assert_contains "${_OUT}" "cache hit: chrome-linux64.zip" "no network needed for a verified copy"
t_assert_contains "${_OUT}" "RC=0"
printf 'tampered' >> "${_CACHED}"
t_assert_contains "$(_cft_run amd64 "${_W}/cache")" "RC=1" "a tampered cache entry is dropped, never trusted"
t_assert_fails test -e "${_CACHED}"
mv "${_W}/held.zip" "${_FIX}/chrome-linux64.zip"
t_assert_contains "$(_cft_run amd64 "${_W}/cache")" "RC=0" "and the next verified download replaces it"

# --- Android emulator ---
_emu_fixture() {
  local build="${1:-16428233}" rev="${2:-9}" d="${_W}/src-emu"
  rm -rf "${d}"; mkdir -p "${d}/emulator/qemu/linux-x86_64" "${d}/x86_64"
  printf '#!/bin/sh\necho "Android emulator version 37.2.12.0 (build_id %s) (CL:N/A)"\n' "${build}" > "${d}/emulator/emulator"
  printf '#!/bin/sh\nexit 0\n' > "${d}/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless"
  chmod +x "${d}/emulator/emulator" "${d}/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless"
  printf 'Pkg.Revision=37.2.12\nPkg.Path=emulator\nPkg.BuildId=%s\n' "${build}" > "${d}/emulator/source.properties"
  printf 'Pkg.Revision=%s\nAndroidVersion.ApiLevel=35\nSystemImage.Abi=x86_64\nSystemImage.TagId=google_apis\n' "${rev}" \
    > "${d}/x86_64/source.properties"
  : > "${d}/x86_64/system.img"
  rm -f "${_FIX}/emulator-linux_x64-16428233.zip" "${_FIX}/x86_64-35_r09.zip"
  _zip "${_FIX}/emulator-linux_x64-16428233.zip" "${d}/emulator"
  _zip "${_FIX}/x86_64-35_r09.zip" "${d}/x86_64"
  {
    printf 'ANDROID_EMULATOR_VERSION=37.2.12\nANDROID_EMULATOR_BUILD=16428233\nANDROID_EMULATOR_API=35\n'
    printf 'ANDROID_EMULATOR_SYSIMG_REVISION=9\n'
    printf 'ANDROID_EMULATOR_SHA256=%s\n' "$(_sha "${_FIX}/emulator-linux_x64-16428233.zip")"
    printf 'ANDROID_EMULATOR_SYSIMG_SHA256=%s\n' "$(_sha "${_FIX}/x86_64-35_r09.zip")"
  } > "${_W}/emu.env"
}
# _emu_run <arch>: the installer into a throwaway SDK.
_emu_run() {
  _run "${EMU}" EMU_ARCH="$1" ANDROID_HOME="${_W}/sdk" ANDROID_PAYLOAD_DIR="${_W}/android" VERSIONS_ENV="${_W}/emu.env"
}

t_case "an amd64 install unpacks the pinned emulator and system image where the emulator looks"
rm -rf "${_W:?}/sdk" "${_W}/android"; mkdir -p "${_W}/sdk/platform-tools" "${_W}/android"
_emu_fixture
_OUT="$(_emu_run amd64)"
t_assert_contains "${_OUT}" "RC=0"
t_assert_contains "${_OUT}" "OK: emulator 37.2.12 and system-images;android-35;google_apis;x86_64 r9"
t_assert_ok test -f "${_W}/sdk/system-images/android-35/google_apis/x86_64/system.img"
t_assert_contains "$(cat "${_FIX}/requested")" "https://dl.google.com/android/repository/sys-img/google_apis/x86_64-35_r09.zip"

t_case "a system image or emulator other than the pin fails the install (mutation)"
_emu_fixture 16428233 8
_OUT="$(_emu_run amd64)"
t_assert_contains "${_OUT}" "Pkg.Revision=8, the pin says 9"
_emu_fixture 16428234
t_assert_contains "$(_emu_run amd64)" "Pkg.BuildId=16428234, the pin says 16428233"

t_case "an emulator zip off its checksum is refused (mutation)"
_emu_fixture
sed -i "s/^ANDROID_EMULATOR_SHA256=.*/ANDROID_EMULATOR_SHA256=${_ZERO}/" "${_W}/emu.env"
t_assert_contains "$(_emu_run amd64)" "Checksum verification FAILED"

t_case "arm64, and an image without an SDK, record why there is no emulator"
_emu_fixture
rm -rf "${_W:?}/sdk" "${_W}/android"; mkdir -p "${_W}/sdk/platform-tools" "${_W}/android"
_OUT="$(_emu_run arm64)"
t_assert_contains "${_OUT}" "RC=0"
t_assert_contains "$(cat "${_W}/android/.android-emulator-off")" "x86_64 hosts only"
t_assert_fails test -e "${_W}/sdk/emulator"
rm -f "${_W}/android/.android-emulator-off"
: > "${_W}/android/.android-payload-off"
t_assert_contains "$(_emu_run amd64)" "no Android SDK in this image"
t_assert_contains "$(cat "${_W}/android/.android-emulator-off")" ".android-payload-off"

t_case "an SDK without platform-tools is an error, not an emulator without adb"
rm -rf "${_W:?}/sdk" "${_W}/android"; mkdir -p "${_W}/sdk" "${_W}/android"
t_assert_contains "$(_emu_run amd64)" "has no platform-tools"

# --- android-avd.sh ---
_avd() { env -u ANDROID_USER_HOME -u ANDROID_AVD_HOME ANDROID_HOME="${_W}/avdsdk" HOME="${_W}/home" AVD_KVM_DEVICE="${_W}/nokvm" AVD_BOOT_TIMEOUT=5 bash "${AVD}" "$@" 2>&1; }
rm -rf "${_W:?}/avdsdk" "${_W:?}/home"
mkdir -p "${_W}/avdsdk/system-images/android-35/google_apis/x86_64"
printf 'AndroidVersion.ApiLevel=35\nSystemImage.TagId=google_apis\n' \
  > "${_W}/avdsdk/system-images/android-35/google_apis/x86_64/source.properties"

t_case "create writes an AVD on the one installed x86_64 image, without avdmanager"
t_assert_contains "$(_avd create ci)" "OK: AVD ci (android-35 google_apis x86_64)"
_CFG="$(cat "${_W}/home/.android/avd/ci.avd/config.ini")"
t_assert_contains "${_CFG}" "image.sysdir.1=system-images/android-35/google_apis/x86_64/"
t_assert_contains "${_CFG}" "target=android-35"
t_assert_contains "${_CFG}" "hw.gpu.mode=swiftshader_indirect"
t_assert_contains "$(cat "${_W}/home/.android/avd/ci.ini")" "path=${_W}/home/.android/avd/ci.avd"

t_case "zero or two system images are refused rather than guessed"
mkdir -p "${_W}/avdsdk/system-images/android-36/google_apis/x86_64"
t_assert_contains "$(_avd create two)" "more than one x86_64 system image"
rm -rf "${_W:?}/avdsdk/system-images"
t_assert_contains "$(_avd create none)" "the emulator ships in the amd64 image only"

t_case "start without a usable /dev/kvm says how to pass it in"
t_assert_contains "$(_avd start ci)" "--device /dev/kvm"
t_assert_eq 2 "$(t_rc env ANDROID_HOME="${_W}/avdsdk" bash "${AVD}" bogus)" "an unknown verb is a usage error"

# --- image wiring ---
_PKG_STAGE="$(sed -n '/^FROM \${PACKAGE_BASE_STAGE} AS package$/,/^FROM /p' "${PKGF}")"

t_case "the package stage installs both, last, with the emulator first"
_RUNS=()
while IFS=: read -r _n _; do _RUNS+=("${_n}"); done < <(printf '%s\n' "${_PKG_STAGE}" | grep -n \
  -e 'deepstream.sh assert-absent' -e 'install-android-emulator.sh,target' -e 'install-chrome-for-testing.sh,target')
t_assert_eq 3 "${#_RUNS[@]}" "the DeepStream RUN and both installer RUNs are found"
t_assert_ok test "${_RUNS[0]:-0}" -lt "${_RUNS[1]:-0}"
t_assert_ok test "${_RUNS[1]:-0}" -lt "${_RUNS[2]:-0}"

t_case "CHROME_EXECUTABLE names the wrapper and is empty on riscv64"
t_assert_contains "${_PKG_STAGE}" $'ARG CHROME_ON=${CHROME_ARCH/riscv64/}\nENV CHROME_EXECUTABLE=${CHROME_ON:+/usr/local/bin/chrome}'
t_assert_eq "1" "$(grep -c 'CHROME_EXECUTABLE=' "${PKGF}")" "one ENV, set where the wrapper is installed"

t_case "the final image ships the AVD helper on PATH"
t_assert_contains "$(cat "${TORCHF}")" "COPY --chmod=755 linux/scripts/04-runtime/android-avd.sh /usr/local/bin/android-avd.sh"

t_summary
