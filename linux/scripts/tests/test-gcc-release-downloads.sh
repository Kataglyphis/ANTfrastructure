#!/usr/bin/env bash
# Local wget/GPG/checksum stubs cover release argv, cache reuse and fatal proof failures without downloading or building GCC.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GCC_SCRIPT="${1:-${TESTS_DIR}/../02-toolchain/build-gcc.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
functions=(fetch_gcc_tarball verify_gcc_sha512 verify_gcc_gpg_signature _gcc_gpg_require_or_warn _gcc_sha_unverified_or_die)
if grep -q '^_gcc_download_release_asset() {' "${GCC_SCRIPT}"; then functions+=(_gcc_download_release_asset); fi
for fn in "${functions[@]}"; do t_fn_src "${GCC_SCRIPT}" "${fn}" >> "${WORK}/library.sh" || exit 1; done
cat > "${WORK}/worker.sh" <<'BASH'
set -euo pipefail
source "$1"
scenario="$2"; cd "$3"
TARBALL=fixture.tar.xz
MIRROR_TARBALL_URL='https://fixture.invalid/path with spaces/fixture.tar.xz'
TARBALL_URL=https://canonical.invalid/fixture.tar.xz
SHA_URL=https://canonical.invalid/sha512.sum
SIG_URL=https://canonical.invalid/fixture.tar.xz.sig
GCC_GPG_KEYS=ACCEPTED
_gcc_probe_url() { return 0; }
wget() {
  printf 'CALL\n' >> calls
  printf 'ARG=%s\n' "$@" >> calls
  local previous='' url='' output='' argument
  for argument in "$@"; do
    if [ "$previous" = -O ]; then output="$argument"; fi
    case "$argument" in https://*) url="$argument" ;; esac
    previous="$argument"
  done
  case "${scenario}:${url}" in
    fallback:*fixture.invalid*|both-fail:*fixture.invalid*) return 4 ;;
    both-fail:*canonical.invalid*) return 8 ;;
    signature-fail:*|checksum-fail:*) return 4 ;;
  esac
  if [ "$output" = sha512.sum ]; then printf 'expected  fixture.tar.xz\n' > "$output"
  else printf downloaded > "${output:-${url##*/}}"; fi
}
gpg() {
  if [ "$1" = --list-keys ]; then return 0; fi
  if [ "$scenario" = signature-bad ]; then printf '[GNUPG:] BADSIG bad\n'
  else printf '[GNUPG:] GOODSIG accepted\n[GNUPG:] VALIDSIG ACCEPTED proof ACCEPTED\n'; fi
}
sha512sum() { [ "$scenario" != checksum-bad ]; }
case "$scenario" in
  existing) printf existing > "$TARBALL"; fetch_gcc_tarball ;;
  cached)
    GCC_TARBALL_CACHE_DIR="$PWD/cache"; mkdir cache
    printf cached > "cache/$TARBALL"
    fetch_gcc_tarball ;;
  mirror|fallback|both-fail) fetch_gcc_tarball ;;
  signature-fail|signature-good|signature-bad) verify_gcc_gpg_signature ;;
  checksum-fail|checksum-good|checksum-bad) verify_gcc_sha512 ;;
esac
printf '%s\n' FINISHED
BASH

_assert_download_call() {
  local trace="$1" record="$2" attempts="$3" url="$4" output="${5:-}"
  local arguments=()
  mapfile -t arguments < <(awk -v wanted="${record}" '/^CALL$/ { n++; next } n == wanted { sub(/^ARG=/, ""); print }' "${trace}")
  t_assert_eq -c "${arguments[0]:-}" 'downloads remain resumable'
  t_assert_eq --https-only "${arguments[1]:-}" 'release assets require TLS'
  t_assert_eq --retry-connrefused "${arguments[2]:-}"
  t_assert_eq --waitretry=1 "${arguments[3]:-}"
  t_assert_eq --read-timeout=20 "${arguments[4]:-}"
  t_assert_eq --timeout=20 "${arguments[5]:-}"
  t_assert_eq -t "${arguments[6]:-}"
  t_assert_eq "${attempts}" "${arguments[7]:-}" 'each caller retains its retry budget'
  t_assert_eq "${url}" "${arguments[8]:-}" 'URLs with spaces remain one argument'
  if [ -n "${output}" ]; then
    t_assert_eq 11 "${#arguments[@]}"
    t_assert_eq -O "${arguments[9]:-}"
    t_assert_eq "${output}" "${arguments[10]:-}"
  else
    t_assert_eq 9 "${#arguments[@]}"
  fi
}

for scenario in existing cached mirror fallback both-fail signature-fail checksum-fail signature-good signature-bad checksum-good checksum-bad; do
  t_case "GCC release ${scenario}"
  dir="${WORK}/${scenario}"; mkdir "${dir}"
  rc=0
  out="$(timeout 5 bash "${WORK}/worker.sh" "${WORK}/library.sh" "${scenario}" "${dir}" 2> "${dir}/err")" || rc=$?
  expected_rc=0
  case "${scenario}" in both-fail) expected_rc=8 ;; *-fail|*-bad) expected_rc=1 ;; esac
  t_assert_eq "${expected_rc}" "${rc}"
  if [ "${expected_rc}" = 0 ]; then t_assert_contains "${out}" FINISHED
  else t_assert_fails grep -q FINISHED <<< "${out}"; fi
  case "${scenario}" in
    existing|cached)
      t_assert_fails test -e "${dir}/calls"
      t_assert_eq "${scenario}" "$(cat "${dir}/fixture.tar.xz")" ;;
    mirror)
      t_assert_eq 1 "$(grep -c '^CALL$' "${dir}/calls")"
      _assert_download_call "${dir}/calls" 1 3 'https://fixture.invalid/path with spaces/fixture.tar.xz' fixture.tar.xz
      t_assert_eq downloaded "$(cat "${dir}/fixture.tar.xz")" ;;
    fallback|both-fail)
      t_assert_eq 2 "$(grep -c '^CALL$' "${dir}/calls")"
      _assert_download_call "${dir}/calls" 1 3 'https://fixture.invalid/path with spaces/fixture.tar.xz' fixture.tar.xz
      _assert_download_call "${dir}/calls" 2 5 https://canonical.invalid/fixture.tar.xz ;;
    signature-*)
      t_assert_eq 1 "$(grep -c '^CALL$' "${dir}/calls")"
      _assert_download_call "${dir}/calls" 1 5 https://canonical.invalid/fixture.tar.xz.sig ;;
    checksum-*)
      t_assert_eq 1 "$(grep -c '^CALL$' "${dir}/calls")"
      _assert_download_call "${dir}/calls" 1 5 https://canonical.invalid/sha512.sum sha512.sum ;;
  esac
  case "${scenario}" in
    signature-fail) t_assert_contains "$(cat "${dir}/err")" 'signature exists on server but could not be downloaded; refusing to continue unverified.' ;;
    checksum-fail) t_assert_contains "$(cat "${dir}/err")" 'sha512.sum exists on server but could not be downloaded; refusing to continue unverified.' ;;
    signature-bad) t_assert_contains "$(cat "${dir}/err")" 'GPG verification FAILED' ;;
    checksum-bad) t_assert_contains "$(cat "${dir}/err")" 'SHA512 mismatch - aborting.' ;;
    signature-good) t_assert_contains "${out}" 'GPG signature verified successfully' ;;
    checksum-good) t_assert_contains "${out}" 'SHA512 OK.' ;;
  esac
done
t_summary
