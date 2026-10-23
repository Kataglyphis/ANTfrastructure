#!/usr/bin/env bash
# Lexical containment and mandatory copied companions are tested offline, not filesystem canonicalization or image builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
PROVENANCE="${1:-${TESTS_DIR}/../03-media/ort-provenance.sh}"
GST="${2:-${TESTS_DIR}/../03-media/build/gstreamer/common/gst-onnx-ort.sh}"
EXPECTED="${TESTS_DIR}/path-containment-receipts.txt"
# shellcheck source=../03-media/ort-provenance.sh
source "$PROVENANCE"
# shellcheck source=../03-media/build/gstreamer/common/gst-onnx-ort.sh
source "$GST"
: > "$WORK/receipts"
receipt_case() {
  local label="$1" path="$2" fn rc out
  shift 2
  for fn in _gst_onnx_under _ortg_under; do
    out="$("$fn" "$path" "$@")"; rc=$?
    printf '%s\t%s\t%d\t%q\t' "$label" "$fn" "$rc" "$out" >> "$WORK/receipts"
    printf '%q ' "$path" "$@" >> "$WORK/receipts"
    printf '\n' >> "$WORK/receipts"
  done
}
receipt_case no-roots /root/child
receipt_case empty-root /root/child ''
receipt_case empty-path '' ''
receipt_case empty-path-real-root '' /root
receipt_case exact /root /root
receipt_case child /root/child /root
receipt_case grandchild /root/child/file /root
receipt_case sibling /root-other/child /root
receipt_case shorter /roo /root
receipt_case root-with-slash /root /root/
receipt_case child-with-slash /root/child /root/
receipt_case exact-with-slash /root/ /root/
receipt_case double-path-slash /root//child /root/
receipt_case root-two-slashes /root/child /root//
receipt_case exact-two-slashes /root// /root//
receipt_case double-child-two-slashes /root//child /root//
receipt_case triple-child-two-slashes /root///child /root//
receipt_case filesystem-root / /
receipt_case filesystem-child /child /
receipt_case filesystem-double-child //child /
receipt_case double-root / //
receipt_case double-root-child /child //
receipt_case double-root-double-child //child //
receipt_case relative-exact relative relative
receipt_case relative-child relative/child relative
receipt_case relative-sibling relative-other relative
receipt_case relative-dot ./relative/child relative
receipt_case dot-root ./child .
receipt_case dot-dot-root ../child ..
receipt_case lexical-parent /root/../outside /root
receipt_case literal-star '/a*/file' '/a*'
receipt_case wildcard-not-expanded /actual/file '/a*'
receipt_case literal-question '/a?/file' '/a?'
receipt_case literal-brackets '/a[bc]/file' '/a[bc]'
receipt_case brackets-not-expanded /ab/file '/a[bc]'
receipt_case spaced '/root with spaces/child' '/root with spaces'
receipt_case newline $'/root\nname/child' $'/root\nname'
receipt_case backslash '/root\child' /root
receipt_case percent '/root%s/child' '/root%s'
receipt_case multiple-roots /root/child '' /other /root
receipt_case later-slash-root /root/child /other /root/
receipt_case no-match-many /outside '' /other /root

t_case "all original lexical policies retain exact statuses and output"
t_assert_ok cmp "$EXPECTED" "$WORK/receipts"

t_case "missing copied companion fails before either gate publishes its API"
for layout in 03-media/ort-provenance.sh 03-media/build/gstreamer/common/gst-onnx-ort.sh; do
  mkdir -p "$WORK/tree/${layout%/*}"
  case "$layout" in *gst-*) original="$GST"; symbol=_gst_onnx_under ;; *) original="$PROVENANCE"; symbol=_ortg_under ;; esac
  cp "$original" "$WORK/tree/$layout"
  t_assert_eq 1 "$(t_rc bash -c 'source "$1"' _ "$WORK/tree/$layout")"
  t_assert_eq 1 "$(t_rc bash -c 'source "$1" 2>/dev/null; declare -F "$2"' _ "$WORK/tree/$layout" "$symbol")"
done

t_case "copied gates source the exact shared companion bytes"
mkdir -p "$WORK/tree/01-core"
cp "${TESTS_DIR}/../01-core/path-helpers.sh" "$WORK/tree/01-core/path-helpers.sh"
for layout in 03-media/ort-provenance.sh 03-media/build/gstreamer/common/gst-onnx-ort.sh; do
  t_assert_ok bash -c 'source "$1"; path_under_roots verbatim /root/child /root' _ "$WORK/tree/$layout"
done

t_summary
