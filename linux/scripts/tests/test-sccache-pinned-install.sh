#!/usr/bin/env bash
# base-image.sh's install_sccache_pinned: the asset URL per arch and download base, and no download without a pin.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

FN="$(t_fn_src "${TESTS_DIR}/../01-core/base-image.sh" install_sccache_pinned)" || exit 1

# _url <machine> [VAR=value...]: the URL the installer asks for, or what it logged instead.
_url() {
  local machine="$1"; shift
  env "$@" bash -c 'eval "$1"; _stub_machine="$2"
    uname() { printf "%s\n" "${_stub_machine}"; }
    log() { echo "LOG $*"; }; warn() { echo "WARN $*"; }
    download_verified_file() { echo "URL $1 SHA $2"; return 1; }
    install_sccache_pinned' _ "${FN}" "${machine}" 2>&1 | head -n 1
}

PINS=(SCCACHE_LINUX_VERSION=0.18.0-1bd7432-pr2809 SCCACHE_LINUX_X86_64_SHA256=aa
  SCCACHE_LINUX_AARCH64_SHA256=bb SCCACHE_LINUX_RISCV64_SHA256=cc)
HUB=https://github.com/Kataglyphis/ANTfrastructure/releases/download/sccache-v

t_case "the hub's release, by the same asset names as upstream's, for all three arches"
t_assert_eq "URL ${HUB}0.18.0-1bd7432-pr2809/sccache-v0.18.0-1bd7432-pr2809-x86_64-unknown-linux-musl.tar.gz SHA aa" \
  "$(_url x86_64 "${PINS[@]}" SCCACHE_DOWNLOAD_BASE="${HUB}")"
t_assert_eq "URL ${HUB}0.18.0-1bd7432-pr2809/sccache-v0.18.0-1bd7432-pr2809-aarch64-unknown-linux-musl.tar.gz SHA bb" \
  "$(_url aarch64 "${PINS[@]}" SCCACHE_DOWNLOAD_BASE="${HUB}")"
t_assert_eq "URL ${HUB}0.18.0-1bd7432-pr2809/sccache-v0.18.0-1bd7432-pr2809-riscv64gc-unknown-linux-musl.tar.gz SHA cc" \
  "$(_url riscv64 "${PINS[@]}" SCCACHE_DOWNLOAD_BASE="${HUB}")"

t_case "without a download base it is mozilla's release again"
t_assert_eq "URL https://github.com/mozilla/sccache/releases/download/v0.19.0/sccache-v0.19.0-x86_64-unknown-linux-musl.tar.gz SHA aa" \
  "$(_url x86_64 SCCACHE_LINUX_VERSION=0.19.0 SCCACHE_LINUX_X86_64_SHA256=aa)"

t_case "no pinned SHA or no asset for the arch: nothing is downloaded"
t_assert_contains "$(_url riscv64 SCCACHE_LINUX_VERSION=0.18.0)" "WARN no SHA256 pinned for sccache/riscv64gc-unknown-linux-musl"
t_assert_contains "$(_url s390x "${PINS[@]}")" "LOG No pinned sccache asset for s390x"

t_summary
