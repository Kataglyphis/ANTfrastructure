#!/usr/bin/env bash
# download_verified_install against a stubbed download_file: staging, one rename, cleanup, and the lost-race case; see linux/scripts/01-core/downloads.sh
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
DOWNLOADS="$(cd "${TESTS_DIR}/.." && pwd)/01-core/downloads.sh"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# The release assets: a bare binary and a tarball holding one under a top directory.
mkdir -p "${_WORK}/src/tool-1.0"
printf '#!/bin/sh\necho tool\n' > "${_WORK}/src/tool"
cp "${_WORK}/src/tool" "${_WORK}/src/tool-1.0/tool"
tar -czf "${_WORK}/src/tool-1.0.tar.gz" -C "${_WORK}/src" tool-1.0
_sha() { sha256sum "$1" | awk '{print $1}'; }
SHA_BIN="$(_sha "${_WORK}/src/tool")"
SHA_TGZ="$(_sha "${_WORK}/src/tool-1.0.tar.gz")"

# _install <dest> <url name> <sha> [member] [lose]: prints rc|where the download landed; "lose" makes every mv fail.
_install() {
  local dest="$1" name="$2" sha="$3" member="${4:-}" lose="${5:-}"
  bash -c '
    source "$1"
    work="$6"
    download_file() { printf "%s\n" "$2" > "${work}/landed"; cp "${work}/src/${1##*/}" "$2"; }
    [ -n "$5" ] && mv() { return 1; }
    download_verified_install "https://example.invalid/$2" "$3" "$7" "$4"; rc=$?
    printf "%s|%s" "${rc}" "$(cat "${work}/landed" 2>/dev/null)"
  ' _ "${DOWNLOADS}" "${name}" "${sha}" "${member}" "${lose}" "${_WORK}" "${dest}" 2>/dev/null
}
_stages() { find "$1" -maxdepth 1 -name '.stage.*' | wc -l | tr -d ' '; }

t_case "a bare binary: downloaded into a stage beside the destination, never onto it"
out="$(_install "${_WORK}/c1/tool" tool "${SHA_BIN}")"
t_assert_eq "0" "${out%%|*}"
t_assert_contains "${out#*|}" "${_WORK}/c1/.stage." "the bytes land in the stage, so a parallel caller cannot see half of them"
t_assert_eq "tool" "$("${_WORK}/c1/tool")" "the installed file is the executable binary"
t_assert_eq "0" "$(_stages "${_WORK}/c1")" "the stage is removed"

t_case "an archive member is unpacked in the stage and moved into place"
out="$(_install "${_WORK}/c2/tool" tool-1.0.tar.gz "${SHA_TGZ}" tool-1.0/tool)"
t_assert_eq "0" "${out%%|*}"
t_assert_eq "tool" "$("${_WORK}/c2/tool")"
t_assert_eq "0" "$(_stages "${_WORK}/c2")"

t_case "a checksum mismatch installs nothing and leaves no stage"
out="$(_install "${_WORK}/c3/tool" tool deadbeef)"
t_assert_eq "1" "${out%%|*}"
t_assert_eq "absent" "$([ -e "${_WORK}/c3/tool" ] && echo present || echo absent)"
t_assert_eq "0" "$(_stages "${_WORK}/c3")"

t_case "an archive without the member fails, it never installs the archive itself"
out="$(_install "${_WORK}/c4/tool" tool-1.0.tar.gz "${SHA_TGZ}" tool-1.0/missing)"
t_assert_eq "1" "${out%%|*}"
t_assert_eq "absent" "$([ -e "${_WORK}/c4/tool" ] && echo present || echo absent)"

t_case "a lost race is a success when the winner's binary is in place, a failure when nothing is"
mkdir -p "${_WORK}/c5" && cp "${_WORK}/src/tool" "${_WORK}/c5/tool" && chmod +x "${_WORK}/c5/tool"
out="$(_install "${_WORK}/c5/tool" tool "${SHA_BIN}" "" lose)"
t_assert_eq "0" "${out%%|*}" "Windows refuses to replace a running .exe; the winner's copy is the same pinned bytes"
out="$(_install "${_WORK}/c6/tool" tool "${SHA_BIN}" "" lose)"
t_assert_eq "1" "${out%%|*}" "a failed rename with nothing in place is a failed install"
t_assert_eq "0" "$(_stages "${_WORK}/c6")"

t_summary
