#!/usr/bin/env bash
# setup-asset-mirror.sh and set-asset-mirror.sh against stubbed garage, scp, ssh and curl; not covered: a real Garage or its key output format.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
SETUP="${REPO}/linux/sccache-s3/setup-asset-mirror.sh"
SET="${REPO}/linux/host-config/set-asset-mirror.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin" STATE="${WORK}/garage" REMOTE="${WORK}/remote" HOMEDIR="${WORK}/home"
mkdir -p "${BIN}" "${STATE}" "${REMOTE}" "${HOMEDIR}"
: > "${WORK}/garage.toml"

cat > "${BIN}/garage" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STATE}/calls"
case "$1 $2" in
  "bucket info") [ -f "${STATE}/bucket-$3" ] ;;
  "bucket create") : > "${STATE}/bucket-$3" ;;
  "bucket allow") : ;;
  "key create") : > "${STATE}/key-$3" ;;
  "key info")
    if [ "$3" = --show-secret ]; then
      [ -f "${STATE}/garbled" ] && { printf 'Key ID: GK%s\n' "$4"; exit 0; }
      printf 'Key name: %s\nKey ID: GK%s\nSecret key: secret-%s\n' "$4" "$4" "$4"
    else
      [ -f "${STATE}/key-$3" ]
    fi ;;
  *) exit 9 ;;
esac
EOF
# scp and ssh act on this machine, as the Garage host would; REMOTE stands in for its filesystem.
cat > "${BIN}/scp" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -q ] && shift
cp "${1#*:}" "$2"
EOF
cat > "${BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "${REMOTE}/ssh-calls"
TMPDIR="${REMOTE}" eval "$2"
EOF
# curl answers by key and method: the read key may not PUT, unless CURL_READ_WRITES says it can.
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
cfg="$(cat)"; method=GET
for a in "$@"; do [ "${prev:-}" = -X ] && method="${a}"; prev="${a}"; done
case "${cfg}" in *GKasset-mirror-read:*) key=read ;; *GKasset-mirror-fill:*) key=fill ;; *) exit 7 ;; esac
[ "${key}" = read ] && [ "${method}" != GET ] && [ -z "${CURL_READ_WRITES:-}" ] && exit 22
exit 0
EOF
chmod +x "${BIN}"/*
export STATE REMOTE
_env() { env PATH="${BIN}:${PATH}" HOME="${HOMEDIR}" XDG_CONFIG_HOME="${HOMEDIR}/.config" GARAGE_CONFIG_FILE="${WORK}/garage.toml" "$@"; }
_setup() { _env bash "${SETUP}" "$@" 2>&1; }

t_case "the Garage side creates the bucket and both keys, and writes two mode-600 env files"
mkdir -p "${REMOTE}/root"
t_assert_rc 0 _setup --url http://s3.invalid:3900/release-assets/ --out "${REMOTE}/root"
t_assert_rc 0 _setup --url http://s3.invalid:3900/release-assets/ --out "${REMOTE}/root"
t_assert_eq "600 600" "$(stat -c '%a' "${REMOTE}/root/asset-mirror-read.env" "${REMOTE}/root/asset-mirror-fill.env" | tr '\n' ' ' | sed 's/ $//')"
t_assert_eq "ASSET_MIRROR_URL=http://s3.invalid:3900/release-assets
AWS_ACCESS_KEY_ID=GKasset-mirror-read
AWS_SECRET_ACCESS_KEY=secret-asset-mirror-read
AWS_REGION=garage" "$(cat "${REMOTE}/root/asset-mirror-read.env")"
t_assert_contains "$(cat "${STATE}/calls")" "bucket allow --read --write release-assets --key asset-mirror-fill"

t_case "a second run reuses the bucket and the keys, so every host shares them"
t_assert_eq "1" "$(grep -c '^bucket create' "${STATE}/calls")"
t_assert_eq "2" "$(grep -c '^key create' "${STATE}/calls")"

t_case "a URL for another bucket and an unparseable key both stop with rc 2"
t_assert_rc 2 _setup --url http://s3.invalid:3900/sccache --out "${REMOTE}/root"
t_assert_rc 2 _setup --out "${REMOTE}/root"
t_assert_rc 1 _setup --url
: > "${STATE}/garbled"
t_assert_rc 2 _setup --url http://s3.invalid:3900/release-assets --out "${REMOTE}/root"
rm -f "${STATE}/garbled"

t_case "the host side installs both files mode 600, removes the Garage host's copies, then proves the rights"
out="$(_env bash "${SET}" --from root@s3.invalid --remote-dir "${REMOTE}/root" 2>&1)"; rc=$?
t_assert_eq "0" "${rc}" "${out}"
t_assert_eq "600 600" "$(stat -c '%a' "${HOMEDIR}/.config/kataglyphis/asset-mirror.env" "${HOMEDIR}/.config/kataglyphis/asset-mirror-fill.env" | tr '\n' ' ' | sed 's/ $//')"
t_assert_eq "absent" "$([ -e "${REMOTE}/root/asset-mirror-read.env" ] || [ -e "${REMOTE}/root/asset-mirror-fill.env" ] && echo present || echo absent)"
t_assert_contains "${out}" "OK   read key cannot write"
t_assert_contains "${out}" "both keys work"

t_case "--url runs the setup on the Garage host from the shipped closure alone, then removes it"
out="$(_env bash "${SET}" --from root@s3.invalid --url http://s3.invalid:3900/release-assets --remote-dir "${REMOTE}/root" 2>&1)"; rc=$?
t_assert_eq "0" "${rc}" "${out}"
t_assert_contains "$(cat "${REMOTE}/ssh-calls")" "/sccache-s3/setup-asset-mirror.sh --url http://s3.invalid:3900/release-assets"
t_assert_eq "" "$(find "${REMOTE}" -maxdepth 1 -name 'tmp.*')"
t_assert_contains "${out}" "both keys work"
: > "${STATE}/garbled"
t_assert_rc 2 _env bash "${SET}" --from root@s3.invalid --url http://s3.invalid:3900/release-assets --remote-dir "${REMOTE}/root"
rm -f "${STATE}/garbled"
t_assert_eq "" "$(find "${REMOTE}" -maxdepth 1 -name 'tmp.*')"

t_case "--check fails when the read key can write"
out="$(_env CURL_READ_WRITES=1 bash "${SET}" --check 2>&1)"; rc=$?
t_assert_eq "1" "${rc}" "${out}"
t_assert_contains "${out}" "FAIL read key cannot write"

t_case "--check refuses a key file that is not mode 600, and no mode at all"
chmod 644 "${HOMEDIR}/.config/kataglyphis/asset-mirror.env"
t_assert_rc 2 _env bash "${SET}" --check
chmod 600 "${HOMEDIR}/.config/kataglyphis/asset-mirror.env"
t_assert_rc 2 _env bash "${SET}"

t_summary
