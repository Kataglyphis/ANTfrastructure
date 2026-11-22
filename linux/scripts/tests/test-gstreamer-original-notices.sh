#!/usr/bin/env bash
# Synthetic source staging and conditional-call refusals do not prove actual image or complete binary licences.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/git-fixture-env.sh"
SUBJECT="${TESTS_DIR}/../03-media/build/gstreamer/common/stage-original-notices.py"
work="$(t_mktemp -d)"

plant_gst_notice_source() {
  python3 -B "${TESTS_DIR}/gstreamer_notice_tests.py" --fixture "$1"
}

tree="$(t_consumer_fixture "${work}" plant_gst_notice_source root)" || exit 1
git -C "${tree}" tag 1.29.2 || exit 1
git -C "${tree}" tag gstreamer-1.29.2 || exit 1
t_case 'original notice staging retains bytes, source identity and fatal producer handoffs'
python3 -B "${TESTS_DIR}/gstreamer_notice_tests.py" "${SUBJECT}" "${tree}"
t_assert_eq 0 "$?" 'all source notice staging controls pass'
python3 -B "${TESTS_DIR}/image_source_original_tests.py" "${SUBJECT}" "${tree}"
t_assert_eq 0 "$?" 'all image source-original transport controls pass'
t_summary
