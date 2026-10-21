#!/usr/bin/env bash
# check-dart-coverage.sh on synthetic lcov reports: it must pass at the floor, fail below it, and leave generated code out.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
gate="$(cd "${TESTS_DIR}/.." && pwd)/05-frameworks/flutter/check-dart-coverage.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/ws"
ws="$(cd "${work}/ws" && pwd)"

# One record per file: $1 path, $2 lines hit, $3 lines missed.
record() {
  awk -v f="$1" -v hit="$2" -v miss="$3" 'BEGIN {
    print "SF:" f
    for (n = 1; n <= hit + miss; n++) print "DA:" n "," (n <= hit ? 3 : 0)
    print "end_of_record"
  }'
}
seventy() { record "${ws}/lib/a.dart" 7 3; }
# _floor <report> <percent> [arg...]: the gate on one report, against this suite's repo root.
_floor() { bash "$gate" --lcov "${work}/$1.info" --min "$2" --repo-root "$ws" "${@:3}"; }

{ seventy; record "${ws}/lib/b.dart" 0 0; } >"${work}/seventy.info"
t_case "70 % passes a 70 % floor"
t_assert_ok _floor seventy 70
t_case "70 % fails a 71 % floor"
t_assert_fails _floor seventy 71
t_assert_contains "$(t_out _floor seventy 71)" "FAIL: below the floor"

{ seventy; record "${ws}/lib/l10n/app_localizations.dart" 0 200; } >"${work}/l10n.info"
t_case "generated localizations never count"
t_assert_ok _floor l10n 70

{ seventy; record "${ws}/lib/src/rust/frb_generated.dart" 0 500; } >"${work}/bridge.info"
t_case "an --exclude prefix leaves an app's own generated tree out"
t_assert_ok _floor bridge 70 --exclude lib/src/rust/
t_case "without it the generated tree counts"
t_assert_fails _floor bridge 70

{ seventy; record "${ws}/test/helper.dart" 0 50; record /pub-cache/flutter/lib/src/x.dart 0 50; } >"${work}/foreign.info"
t_case "test/ and another package's lib/ do not count"
t_assert_ok _floor foreign 70

{ record lib/a.dart 7 3; } >"${work}/relative.info"
t_case "a path relative to the repo counts"
t_assert_ok _floor relative 70
t_case "a missing --min is refused"
t_assert_rc 2 bash "$gate" --lcov "${work}/seventy.info"
t_case "a fractional --min is refused"
t_assert_rc 2 bash "$gate" --lcov "${work}/seventy.info" --min 70.5
: >"${work}/empty.info"
t_case "an empty report fails"
t_assert_fails bash "$gate" --lcov "${work}/empty.info" --min 0

t_summary
