#!/usr/bin/env bash
# Keeps the sccache bucket under CAP_GB, oldest LastModified first down to TRIM_GB: sccache never deletes an object.
set -euo pipefail

: "${S3_ENDPOINT:?set in /etc/sccache-evict.env}"
: "${S3_BUCKET:=sccache}"
: "${CAP_GB:=60}"
: "${TRIM_GB:=54}"
: "${AWS_ACCESS_KEY_ID:?the eviction key, set in /etc/sccache-evict.env}"
: "${AWS_SECRET_ACCESS_KEY:?the eviction key, set in /etc/sccache-evict.env}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# An empty bucket makes ls exit non-zero with "no object found".
if ! s5cmd --endpoint-url "${S3_ENDPOINT}" ls "s3://${S3_BUCKET}/*" > "${work}/listing" 2> "${work}/ls.err"; then
  if grep -q 'no object found' "${work}/ls.err"; then
    echo "sccache-evict: the bucket is empty"
    exit 0
  fi
  cat "${work}/ls.err" >&2
  exit 1
fi

gib=$(( 1024 * 1024 * 1024 ))
total="$(awk '{ s += $3 } END { printf "%.0f", s }' "${work}/listing")"
if (( total <= CAP_GB * gib )); then
  echo "sccache-evict: $(( total / 1024 / 1024 )) MiB, under the ${CAP_GB} GiB cap"
  exit 0
fi

# s5cmd prints "YYYY/MM/DD HH:MM:SS size key", which sorts oldest first as text.
sort -k1,1 -k2,2 "${work}/listing" |
  awk -v excess="$(( total - TRIM_GB * gib ))" -v bucket="${S3_BUCKET}" '
    freed >= excess { exit }
    { freed += $3; print "rm s3://" bucket "/" $4 }' > "${work}/plan"
echo "sccache-evict: $(( total / 1024 / 1024 )) MiB is over the ${CAP_GB} GiB cap; deleting $(wc -l < "${work}/plan") objects down to ${TRIM_GB} GiB"
s5cmd --endpoint-url "${S3_ENDPOINT}" --log error run "${work}/plan"
