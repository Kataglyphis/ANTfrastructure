#!/usr/bin/env bash
# Chrome for Testing is the image's CHROME_EXECUTABLE (CON50); stubbed downloads and recorded probe text, no browser runs here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HUB="$(cd "${TESTS_DIR}/../../.." && pwd)"
PKGF="${HUB}/linux/Dockerfile.package"
SETUP="${HUB}/linux/scripts/06-packaging/setup-package-image.sh"
RT_SMOKE="${HUB}/linux/scripts/06-packaging/smoke-runtime-image.sh"
VENV="${HUB}/linux/scripts/01-core/versions.env"

t_case "the package stage advertises CHROME_EXECUTABLE at the one path the installer writes"
_pkg_stage="$(sed -n '/^FROM \${PACKAGE_BASE_STAGE} AS package$/,/^FROM /p' "${PKGF}")"
t_assert_contains "${_pkg_stage}" $'\nENV CHROME_EXECUTABLE=/opt/chrome-for-testing/chrome\n' \
  "flutter test --platform chrome finds no browser without it"

t_case "versions.env pins the version, a SHA256 per platform, and Renovate sees the version"
_ver="$(sed -n 's/^CHROME_FOR_TESTING_VERSION=//p' "${VENV}")"
t_assert_ok bash -c '[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]' _ "${_ver}"
for _k in CHROME_FOR_TESTING_LINUX64_SHA256 CHROME_FOR_TESTING_LINUX_ARM64_SHA256; do
  t_assert_ok bash -c '[[ "$(sed -n "s/^$1=//p" "$2")" =~ ^[0-9a-f]{64}$ ]]' _ "${_k}" "${VENV}"
done
t_assert_contains "$(grep -B1 '^CHROME_FOR_TESTING_VERSION=' "${VENV}" | head -1)" \
  "# renovate: datasource=custom.chrome-for-testing depName=chrome-for-testing"
t_assert_ok python3 -c 'import json,sys; assert "chrome-for-testing" in json.load(open(sys.argv[1]))["customDatasources"]' \
  "${HUB}/.github/renovate.json"
t_assert_contains "$(grep -A1 'CHROME_FOR_TESTING_VERSION"' "${HUB}/docs/scripts/bump_versions.py")" "spec_chrome_for_testing" \
  "the two SHAs move with the version, which a Renovate datasource cannot compute"

t_case "the package stage installs it, its one missing dependency, and flutter's web SDK"
t_assert_contains "$(t_fn_src "${SETUP}" main)" "install_chrome_for_testing"
t_assert_contains "$(t_fn_src "${SETUP}" select_dev_packages)" "fonts-liberation"
t_assert_contains "$(t_fn_src "${SETUP}" bootstrap_flutter_sdk)" "flutter --suppress-analytics precache --web"

_fns="$(t_fn_src "${SETUP}" _chrome_for_testing_platform)
$(t_fn_src "${SETUP}" install_chrome_for_testing)"
# _install <machine> [VAR=VALUE...]: runs the installer with download/unzip/ldd stubbed; FAKE_* steer the stubs.
_install() {
  local machine="$1"; shift
  local tmp kv; tmp="$(mktemp -d)"
  cat > "${tmp}/versions.env" <<'VE'
CHROME_FOR_TESTING_VERSION=154.0.8037.92
CHROME_FOR_TESTING_LINUX64_SHA256=aaaa
CHROME_FOR_TESTING_LINUX_ARM64_SHA256=bbbb
VE
  (
    set -uo pipefail
    export VERSIONS_ENV="${tmp}/versions.env" CHROME_FOR_TESTING_PREFIX="${tmp}/prefix" FAKE_MACHINE="${machine}"
    for kv in "$@"; do export "${kv?}"; done
    uname() { printf '%s\n' "${FAKE_MACHINE}"; }
    download_verified_file() { printf 'DOWNLOAD %s SHA %s\n' "$1" "$2"; [ "${FAKE_DL_RC:-0}" = 0 ] && : > "$3"; return "${FAKE_DL_RC:-0}"; }
    unzip() {
      local d="${*: -1}" p="${FAKE_DIR_NAME:-}"
      mkdir -p "${d}/${p}"
      printf '#!/bin/sh\necho "%s"\n' "${FAKE_VERSION_OUT:-Google Chrome for Testing 154.0.8037.92 }" > "${d}/${p}/chrome"
      chmod +x "${d}/${p}/chrome"
    }
    ldd() { [ -n "${FAKE_LDD_MISSING:-}" ] && printf '\tlibnss3.so => not found\n'; return 0; }
    eval "${_fns}"
    case "${machine}" in x86_64) FAKE_DIR_NAME=chrome-linux64 ;; aarch64) FAKE_DIR_NAME=chrome-linux-arm64 ;; esac
    export FAKE_DIR_NAME
    install_chrome_for_testing
    printf 'EXIT %s\n' "$?"
    [ -x "${tmp}/prefix/chrome" ] && echo "INSTALLED"
  ) 2>&1
  rm -rf "${tmp}"
}

t_case "amd64 and arm64 fetch their own platform's zip with their own SHA, and install it"
_out="$(_install x86_64)"
t_assert_contains "${_out}" "DOWNLOAD https://storage.googleapis.com/chrome-for-testing-public/154.0.8037.92/linux64/chrome-linux64.zip SHA aaaa"
t_assert_contains "${_out}" "EXIT 0"
t_assert_contains "${_out}" "INSTALLED"
_out="$(_install aarch64)"
t_assert_contains "${_out}" "DOWNLOAD https://storage.googleapis.com/chrome-for-testing-public/154.0.8037.92/linux-arm64/chrome-linux-arm64.zip SHA bbbb"
t_assert_contains "${_out}" "INSTALLED"

t_case "riscv64 has no upstream build: nothing is downloaded, and the build goes on"
_out="$(_install riscv64)"
t_assert_contains "${_out}" "NOTE: no Chrome for Testing build for riscv64"
t_assert_contains "${_out}" "EXIT 0"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c '^DOWNLOAD' || true)" "no download on riscv64"

t_case "an unpinned SHA, a failed download, a missing library or the wrong version fails the stage"
_out="$(_install x86_64 CHROME_FOR_TESTING_LINUX64_SHA256= VERSIONS_ENV=/nonexistent)"
t_assert_contains "${_out}" "CHROME_FOR_TESTING_VERSION or CHROME_FOR_TESTING_LINUX64_SHA256 is not pinned"
t_assert_contains "${_out}" "EXIT 1" "no unverified bytes"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c '^DOWNLOAD' || true)" "nothing is fetched without a SHA to check it against"
t_assert_contains "$(_install x86_64 FAKE_DL_RC=1)" "EXIT 1"
_out="$(_install x86_64 FAKE_LDD_MISSING=1)"
t_assert_contains "${_out}" "misses shared libraries"
t_assert_contains "${_out}" "EXIT 1"
_out="$(_install aarch64 'FAKE_VERSION_OUT=Google Chrome for Testing 1.0.0.0')"
t_assert_contains "${_out}" "not Chrome for Testing 154.0.8037.92"
t_assert_contains "${_out}" "EXIT 1"

_SB="$(t_rt_sandbox)"; trap 'rm -rf "${_SB}"' EXIT
# $1 = arch, $2 = what the in-image probe printed.
_chk() { t_rt_recorded "${_SB}" "$2" "CHROME_FOR_TESTING_VERSION=154.0.8037.92 check_chrome_for_testing img $1"; }
_OK=$'EXE /opt/chrome-for-testing/chrome\nVERSION Google Chrome for Testing 154.0.8037.92\nDOM chrome-smoke-ok\nWEB_SDK yes'

t_case "the smoke runs the Chrome check"
t_assert_contains "$(t_fn_src "${RT_SMOKE}" main)" 'check_chrome_for_testing "${image_tag}" "${target_arch}"'

t_case "only an emulated arch gets the qemu-user flags; natively they hang Chrome"
# $1 = arch: the _rt_run arguments the check hands over, on an amd64 build host.
_args() {
  local f; f="$(mktemp)"
  ARGF="${f}" bash -c "source '${_SB}/rt.sh' >/dev/null 2>&1; smoke_host_arch() { echo amd64; }
_rt_run() { printf '%s\\n' \"\$*\" > \"\${ARGF}\"; }; check_chrome_for_testing img $1 >/dev/null 2>&1"
  cat "${f}"; rm -f "${f}"
}
t_assert_contains "$(_args arm64)" "-e CHROME_SMOKE_FLAGS=--no-zygote --in-process-gpu --disable-gpu" "arm64 on an amd64 host is emulated"
t_assert_contains "$(_args amd64)" "-e CHROME_SMOKE_FLAGS= bash" "amd64 on an amd64 host is native"

t_case "a pinned Chrome that renders, plus the precached web SDK, passes on amd64 and arm64"
for _a in amd64 arm64; do
  t_assert_contains "$(_chk "${_a}" "${_OK}")" "FAILURES=0" "${_a}"
done

t_case "riscv64 passes only with no Chrome, and still needs the ENV"
t_assert_contains "$(_chk riscv64 $'EXE /opt/chrome-for-testing/chrome\nNO_CHROME')" "FAILURES=0"
t_assert_contains "$(_chk riscv64 "${_OK}")" "FAILURES=1" "a riscv64 Chrome is not upstream's"
t_assert_contains "$(_chk riscv64 $'EXE unset\nNO_CHROME')" "FAILURES=1"

t_case "each missing piece fails on its own"
t_assert_contains "$(_chk amd64 "${_OK/EXE \/opt\/chrome-for-testing\/chrome/EXE unset}")" "FAILURES=1" "no ENV"
t_assert_contains "$(_chk amd64 $'EXE /opt/chrome-for-testing/chrome\nNO_CHROME')" "FAILURES=1" "no browser"
t_assert_contains "$(_chk arm64 "${_OK/154.0.8037.92/153.0.0.1}")" "FAILURES=1" "a version off the pin"
t_assert_contains "$(_chk amd64 "${_OK/DOM chrome-smoke-ok/}")" "FAILURES=1" "rendered nothing"
t_assert_contains "$(_chk arm64 "${_OK/WEB_SDK yes/}")" "FAILURES=1" "web SDK not precached"

t_summary
