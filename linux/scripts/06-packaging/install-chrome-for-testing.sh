#!/usr/bin/env bash
set -euo pipefail

# Chrome for Testing and chromedriver for browser tests: docs/consumer-image-contract.md#browser-tests-run-in-chrome-for-testing

: "${CFT_PREFIX:=/opt/chrome-for-testing}"
: "${CFT_BIN_DIR:=/usr/local/bin}"
: "${TEST_RUNTIMES_CACHE_DIR:=}"
: "${CFT_SKIP_APT:=0}"
: "${TR_CORE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd || echo /opt/scripts/core)}"
: "${VERSIONS_ENV:=${TR_CORE_DIR}/versions.env}"

# Ubuntu 26.04 names for the zip's deb.deps, minus wget and xdg-utils, which a test browser never calls.
CFT_RUNTIME_PACKAGES=(
  ca-certificates fonts-liberation libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64
  libcairo2 libcups2t64 libcurl4t64 libdbus-1-3 libexpat1 libgbm1 libglib2.0-0t64 libgtk-3-0t64 libnspr4
  libnss3 libpango-1.0-0 libudev1 libvulkan1 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3
  libxkbcommon0 libxrandr2
)

cft_platform() {
  case "$1" in
    amd64) printf '%s' linux64 ;;
    arm64) printf '%s' linux-arm64 ;;
    *) return 1 ;;
  esac
}

# <component> <platform>: the versions.env key holding that zip's sha256.
cft_sha_key() {
  local c p
  case "$1" in chrome) c=CHROME_FOR_TESTING ;; chromedriver) c=CHROMEDRIVER ;; *) return 1 ;; esac
  case "$2" in linux64) p=LINUX64 ;; linux-arm64) p=LINUX_ARM64 ;; *) return 1 ;; esac
  printf '%s_%s_SHA256' "${c}" "${p}"
}

# <version> <platform> <component>
cft_url() {
  printf 'https://storage.googleapis.com/chrome-for-testing-public/%s/%s/%s-%s.zip' "$1" "$2" "$3" "$2"
}

cft_record_off() {
  mkdir -p "${CFT_PREFIX}"
  printf 'reason=%s\narch=%s\n' "$1" "$2" > "${CFT_PREFIX}/.chrome-off"
}

# <component> <version> <platform>: unpacks to ${CFT_PREFIX}/<component>.
cft_install_component() {
  local component="$1" version="$2" platform="$3" key sha tmp
  key="$(cft_sha_key "${component}" "${platform}")"
  sha="${!key:-}"
  [ -n "${sha}" ] || { echo "ERROR: no ${key} in ${VERSIONS_ENV}; refusing unverified bytes" >&2; return 1; }
  tmp="$(mktemp -d)"
  if ! download_verified_cached "$(cft_url "${version}" "${platform}" "${component}")" "${sha}" \
       "${tmp}/${component}.zip" "${TEST_RUNTIMES_CACHE_DIR}"; then
    rm -rf "${tmp}"
    return 1
  fi
  unzip -q "${tmp}/${component}.zip" -d "${tmp}"
  [ -d "${tmp}/${component}-${platform}" ] || { echo "ERROR: ${component}.zip holds no ${component}-${platform}/" >&2; rm -rf "${tmp}"; return 1; }
  rm -rf "${CFT_PREFIX:?}/${component}"
  mv "${tmp}/${component}-${platform}" "${CFT_PREFIX}/${component}"
  rm -rf "${tmp}"
}

cft_write_wrapper() {
  mkdir -p "${CFT_BIN_DIR}"
  cat > "${CFT_BIN_DIR}/chrome" <<EOF
#!/bin/sh
# No sandbox in a container, no zygote under qemu-user: docs/consumer-image-contract.md#why-the-wrapper-passes---no-sandbox-and---no-zygote
exec "${CFT_PREFIX}/chrome/chrome" --no-sandbox --no-zygote --disable-dev-shm-usage "\$@"
EOF
  chmod 0755 "${CFT_BIN_DIR}/chrome"
  ln -sfn "${CFT_PREFIX}/chromedriver/chromedriver" "${CFT_BIN_DIR}/chromedriver"
}

_cft_is_elf() {
  if [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = 7f454c46 ]; then
    return 0
  fi
  return 1
}

# Every ELF resolves, both binaries report the pin, and a page renders with JavaScript.
cft_verify() {
  local version="$1" f so missing="" got dom
  while IFS= read -r f; do
    _cft_is_elf "${f}" || continue
    while IFS= read -r so; do missing+=" ${f#"${CFT_PREFIX}"/}:${so}"; done < <(elf_unresolved_needed --transitive "${f}")
  done < <(find "${CFT_PREFIX}" -type f \( -perm -u+x -o -name '*.so*' \))
  [ -z "${missing}" ] || { echo "ERROR: unresolved libraries:${missing}" >&2; return 1; }
  got="$("${CFT_BIN_DIR}/chrome" --version 2>&1 || true)"
  case "${got}" in *" ${version}"*) ;; *) echo "ERROR: chrome reports '${got}', pin is ${version}" >&2; return 1 ;; esac
  got="$("${CFT_BIN_DIR}/chromedriver" --version 2>&1 || true)"
  case "${got}" in *" ${version} "*|*" ${version}") ;; *) echo "ERROR: chromedriver reports '${got}', pin is ${version}" >&2; return 1 ;; esac
  dom="$(timeout 300 "${CFT_BIN_DIR}/chrome" --headless --dump-dom \
           'data:text/html,<script>document.write("cft-"+6*7)</script>' 2>/dev/null || true)"
  case "${dom}" in *cft-42*) ;; *) echo "ERROR: headless chrome rendered no page: '${dom:0:200}'" >&2; return 1 ;; esac
  echo "OK: Chrome for Testing ${version} and its chromedriver run, and render headless"
}

main() {
  local arch platform version lib
  for lib in downloads.sh load-versions-env.sh platform.sh; do
    # shellcheck source=/dev/null
    source "${TR_CORE_DIR}/${lib}"
  done
  load_versions_env "${VERSIONS_ENV}"
  : "${CFT_ARCH:=$(dpkg --print-architecture)}"
  arch="${CFT_ARCH}"
  if ! platform="$(cft_platform "${arch}")"; then
    cft_record_off "Chrome for Testing publishes linux64 and linux-arm64 builds only" "${arch}"
    echo "NOTE: no Chrome for Testing build for ${arch}; the image ships no browser there"
    return 0
  fi
  version="${CHROME_FOR_TESTING_VERSION:?CHROME_FOR_TESTING_VERSION is not pinned in ${VERSIONS_ENV}}"

  if [ "${CFT_SKIP_APT}" != 1 ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${CFT_RUNTIME_PACKAGES[@]}"
  fi
  mkdir -p "${CFT_PREFIX}"
  rm -f "${CFT_PREFIX}/.chrome-off"
  cft_install_component chrome "${version}" "${platform}"
  cft_install_component chromedriver "${version}" "${platform}"
  cft_write_wrapper
  cft_verify "${version}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
