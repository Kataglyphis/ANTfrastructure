#!/usr/bin/env bash
# Verified archive fixtures perform no remote download, compiler invocation or GPU execution.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/downloads.sh"
source "${TESTS_DIR}/../03-media/build/hailo/hailo-build-lib.sh"
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
mkdir -p "${w}/source/root/include"
printf 'source bytes\n' > "${w}/source/root/include/header.h"
tar -czf "${w}/fixture.tar.gz" -C "${w}/source" root
sha="$(sha256sum "${w}/fixture.tar.gz" | awk '{print $1}')"
download_file() {
  [ "${DOWNLOAD_FAIL:-0}" = 0 ] || return 7
  cp "${w}/fixture.tar.gz" "$2"
}

t_case "the archive is verified before default-layout extraction and retained for cache reuse"
t_assert_ok hailo_unpack_source_archive https://example.invalid/source "${sha}" "${w}/archive.tar.gz" "${w}/unstripped"
t_assert_eq 'source bytes' "$(cat "${w}/unstripped/root/include/header.h")"
t_assert_ok test -f "${w}/archive.tar.gz"

t_case "strip-components and destination spaces retain their exact source layout"
t_assert_ok hailo_unpack_source_archive https://example.invalid/source "${sha}" "${w}/strip.tar.gz" "${w}/stripped source" 1
t_assert_eq 'source bytes' "$(cat "${w}/stripped source/include/header.h")"
t_assert_fails test -e "${w}/stripped source/root"

t_case "bad checksums never create the extraction destination"
bad=0000000000000000000000000000000000000000000000000000000000000000
t_assert_fails hailo_unpack_source_archive https://example.invalid/source "${bad}" "${w}/bad.tar.gz" "${w}/bad"
t_assert_fails test -e "${w}/bad"

t_case "a failed download cannot reuse an old archive even when its checksum matches"
cp "${w}/fixture.tar.gz" "${w}/stale.tar.gz"
DOWNLOAD_FAIL=1 t_assert_fails hailo_unpack_source_archive https://example.invalid/source "${sha}" "${w}/stale.tar.gz" "${w}/stale"
t_assert_fails test -e "${w}/stale"

t_case "extraction errors remain failures in a conditional caller"
printf 'not a tar archive\n' > "${w}/corrupt"
corrupt_sha="$(sha256sum "${w}/corrupt" | awk '{print $1}')"
download_file() { cp "${w}/corrupt" "$2"; }
t_assert_fails hailo_unpack_source_archive https://example.invalid/source "${corrupt_sha}" "${w}/broken.tar.gz" "${w}/broken"
t_summary
