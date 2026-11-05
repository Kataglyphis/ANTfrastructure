#!/usr/bin/env bash
# Runs sccache-s3-evict's own text with curl, s5cmd and logger stubbed. Out of scope: Garage's listing format and its GC.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
EVICT="${TESTS_DIR}/../../../linux/sccache-s3/sccache-s3-evict"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
mkdir -p "${BIN}"
sed "s#/etc/garage#${WORK}#g" "${EVICT}" > "${WORK}/evict"
printf 'Key ID: GKtest\nSecret key: secret\n' > "${WORK}/evict-key.txt"
printf '[s3_api]\napi_bind_addr = "127.0.0.1:1"\n[admin]\nadmin_token = "token"\n' > "${WORK}/garage.toml"

cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"bytes": %s}\n' "${STUB_BUCKET_BYTES}"
EOF
cat > "${BIN}/s5cmd" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
case "$*" in
  *" ls "*) : > "${STUB_DIR}/listed"; cat "${STUB_DIR}/listing" ;;
  *" run "*) cp "${last}" "${STUB_DIR}/ran" ;;
  *) exit 9 ;;
esac
EOF
cat > "${BIN}/df" <<'EOF'
#!/usr/bin/env bash
printf 'Avail\n%s\n' "${STUB_AVAIL}"
EOF
cat > "${BIN}/garage" <<'EOF'
#!/usr/bin/env bash
printf '  resync queue length:   %s\n' "${STUB_QUEUE}"
EOF
cat > "${BIN}/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_DIR}/logged"
EOF
chmod +x "${BIN}/curl" "${BIN}/s5cmd" "${BIN}/logger" "${BIN}/df" "${BIN}/garage"

# Far more output after the cut than a pipe buffer holds, or an early awk exit would not reach sort.
OBJECTS=300000 NEW=1000 SIZE=10240
awk -v n="${OBJECTS}" -v new="${NEW}" -v size="${SIZE}" 'BEGIN {
  for (i = 1; i <= new; i++) printf "2026/10/02 00:00:00 %d new-%d\n", size, i
  for (i = 1; i <= n - new; i++) printf "2026/10/01 00:00:00 %d old-%d\n", size, i
}' > "${WORK}/listing"
USED=$(( OBJECTS * SIZE ))
TARGET=$(( 1024 ** 3 * 9 / 10 ))
EXPECTED=$(( (USED - TARGET + SIZE - 1) / SIZE ))

export STUB_QUEUE=0
_evict() {
  STUB_DIR="${WORK}" STUB_BUCKET_BYTES="$1" STUB_AVAIL="${AVAIL:-$(( 1024 ** 4 ))}" \
    CAP_GB="${CAP_GB:-1}" MIN_FREE_GB=25 FLOOR_GB="${FLOOR_GB:-1}" PATH="${BIN}:${PATH}" bash "${WORK}/evict"
}

t_case "a bucket over the cap is cut to 90 %, oldest first, with far more listed than deleted"
t_assert_rc 0 _evict "${USED}"
if [ -f "${WORK}/ran" ]; then
  t_assert_eq "${EXPECTED}" "$(wc -l < "${WORK}/ran" | tr -d ' ')" "deleted objects"
  t_assert_eq 0 "$(grep -c 'new-' "${WORK}/ran")" "newer objects deleted"
else
  t_assert_eq present missing "s5cmd run was reached"
fi
t_assert_eq 1 "$(grep -c "was ${USED} bytes" "${WORK}/logged")" "logged size"

t_case "a bucket under the cap is not even listed"
rm -f "${WORK}/listed" "${WORK}/ran"
t_assert_rc 0 _evict 1024
t_assert_eq absent "$([ -e "${WORK}/listed" ] && echo present || echo absent)" "listing"
t_assert_eq absent "$([ -e "${WORK}/ran" ] && echo present || echo absent)" "deletes"

GIB=$(( 1024 ** 3 ))
_case_low_disk() {
  rm -f "${WORK}/listed" "${WORK}/ran"
  AVAIL=$(( 24 * GIB )) STUB_QUEUE="$1" CAP_GB=10 FLOOR_GB="$2" t_assert_rc 0 _evict "${USED}"
}

t_case "under the cap with low free space, the bucket shrinks by the shortfall and a margin"
_case_low_disk 0 1
# 3072000000 bytes under a 10 GiB cap; 1 GiB short plus the 5 GiB margin leaves nothing above a 1 GiB floor.
t_assert_eq "$(( (USED - GIB + SIZE - 1) / SIZE ))" "$(wc -l < "${WORK}/ran" | tr -d ' ')" "deleted down to the floor"

t_case "space a resync is still freeing is not deleted for twice"
_case_low_disk 1001 1
t_assert_eq absent "$([ -e "${WORK}/ran" ] && echo present || echo absent)" "deletes while the resync backlog is high"

t_case "a bucket at the floor is left alone however low free space is"
_case_low_disk 0 10
t_assert_eq absent "$([ -e "${WORK}/ran" ] && echo present || echo absent)" "deletes at the floor"

t_summary
