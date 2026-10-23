#!/usr/bin/env bash
# Metadata and fallback fixtures exercise no real compiler or image build.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/platform.sh"
VALIDATOR="${TESTS_DIR}/../06-packaging/validate-compilers.sh"
VALIDATOR_READER="$(t_fn_src "${VALIDATOR}" _vc_clang_embedded_version)"
eval "${VALIDATOR_READER}"
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
export CLANG_FIXTURE_CALLS="${w}/calls"
compiler="${w}/compiler with spaces"

write_compiler() {
  local metadata="$1"
  printf '#!/usr/bin/env bash\n%s\n' "${metadata}" > "${compiler}"
  cat >> "${compiler}" <<'STUB'
printf '%s\n' "$*" >> "${CLANG_FIXTURE_CALLS}"
printf '%s\n' "${CLANG_FIXTURE_VERSION:-clang version 22.1.0}"
printf 'ignored compiler diagnostic\n' >&2
exit "${CLANG_FIXTURE_RC:-0}"
STUB
  chmod +x "${compiler}"
  : > "${CLANG_FIXTURE_CALLS}"
}

t_case "embedded metadata wins over the runtime library's different version without execution"
write_compiler '# {"version":"1:23.0.0~snapshot"}'
for reader in clang_embedded_deb_version _vc_clang_embedded_version; do
  t_assert_eq 23.0.0 "$("${reader}" "${compiler}")"
done
t_assert_eq '' "$(cat "${CLANG_FIXTURE_CALLS}")"

t_case "the first embedded version wins and an epoch plus Debian suffix is stripped"
write_compiler $'# {"version":"7:24.2.1~build"}\n# {"version":"1:25.0.0~later"}'
t_assert_eq 24.2.1 "$(clang_embedded_deb_version "${compiler}")"

t_case "both readers fall back to --version and leave its stderr quiet"
write_compiler '# no embedded Debian version'
for reader in clang_embedded_deb_version _vc_clang_embedded_version; do
  t_assert_eq 22.1.0 "$("${reader}" "${compiler}" 2>&1)"
done
t_assert_eq $'--version\n--version' "$(cat "${CLANG_FIXTURE_CALLS}")"

t_case "metadata without a Debian epoch retains the historical fallback policy"
write_compiler '# {"version":"23.0.0"}'
t_assert_eq 22.1.0 "$(clang_embedded_deb_version "${compiler}")"

t_case "an unusable compiler keeps the setup and validation failure policies distinct"
CLANG_FIXTURE_VERSION=unrecognized CLANG_FIXTURE_RC=9 \
  t_assert_fails bash -euo pipefail -c 'source "$1"; clang_embedded_deb_version "$2"' _ "${TESTS_DIR}/../01-core/platform.sh" "${compiler}"
t_assert_eq '' "$(CLANG_FIXTURE_VERSION=unrecognized CLANG_FIXTURE_RC=9 _vc_clang_embedded_version "${compiler}")"
t_assert_ok env CLANG_FIXTURE_VERSION=unrecognized CLANG_FIXTURE_RC=9 CLANG_FIXTURE_READER="${VALIDATOR_READER}" \
  bash -euo pipefail -c 'source "$1"; eval "$CLANG_FIXTURE_READER"; _vc_clang_embedded_version "$2"' _ "${TESTS_DIR}/../01-core/platform.sh" "${compiler}"
t_summary
