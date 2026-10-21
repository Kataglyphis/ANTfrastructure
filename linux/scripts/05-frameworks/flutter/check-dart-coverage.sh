#!/usr/bin/env bash
# check-dart-coverage.sh --min PERCENT [--lcov FILE] [--repo-root DIR] [--exclude PREFIX]...: a Flutter app's own lib/ must stay covered. See docs/code-quality-tooling.md#the-dart-coverage-floor
set -euo pipefail

repo_root="$PWD"
lcov=""
min=""
# Generated localizations are no app's to test; --exclude adds an app's own generated trees.
excludes=("lib/l10n/")

usage() {
  printf 'usage: %s --min PERCENT [--lcov FILE] [--repo-root DIR] [--exclude PREFIX]...\n' "$0"
  printf 'Without --lcov it runs flutter test --coverage in the repo root first. lib/l10n/ is always excluded.\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --lcov) lcov="${2:?--lcov needs a file}"; shift 2 ;;
    --min) min="${2:?--min needs a percentage}"; shift 2 ;;
    --repo-root) repo_root="$(cd "${2:?--repo-root needs a path}" && pwd)"; shift 2 ;;
    --exclude) excludes+=("${2:?--exclude needs a path prefix under the repo root}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'check-dart-coverage: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$min" in
  '' ) printf 'check-dart-coverage: --min is required\n' >&2; exit 2 ;;
  *[!0-9]* ) printf 'check-dart-coverage: --min takes a whole percentage, not %s\n' "$min" >&2; exit 2 ;;
esac

if [ -z "$lcov" ]; then
  lcov="${repo_root}/build/coverage/lcov.info"
  rm -f "$lcov"
  (cd "$repo_root" && flutter test --coverage --coverage-path "$lcov")
fi
[ -s "$lcov" ] || { printf 'check-dart-coverage: no coverage data in %s\n' "$lcov" >&2; exit 1; }

# One awk variable: mawk has no arrays as -v values, so the prefixes travel newline-joined.
awk -v min="$min" -v root="$repo_root" -v excluded="$(printf '%s\n' "${excludes[@]}")" '
  BEGIN { n = split(excluded, skip, "\n") }
  /^SF:/ {
    file = substr($0, 4)
    if (index(file, root "/") == 1) file = substr(file, length(root) + 2)
    own = (file ~ /^lib\//)
    for (i = 1; i <= n; i++) if (skip[i] != "" && index(file, skip[i]) == 1) own = 0
    next
  }
  /^DA:/ && own {
    split(substr($0, 4), da, ",")
    total[file]++
    if (da[2] > 0) hit[file]++
    next
  }
  END {
    for (f in total) { all += total[f]; covered += hit[f] }
    if (all == 0) { print "check-dart-coverage: no lib/ lines in the report" > "/dev/stderr"; exit 1 }
    pct = 100 * covered / all
    printf "Dart coverage of lib/ (generated code aside): %d of %d lines, %.1f %% (floor %d %%)\n", covered, all, pct, min
    for (f in total) printf "  %5.1f %%  %4d/%-4d %s\n", 100 * hit[f] / total[f], hit[f], total[f], f | "sort -n | head -5"
    close("sort -n | head -5")
    if (pct < min) { printf "FAIL: below the floor; test what the lowest files above leave out, or justify a lower --min\n"; exit 1 }
  }
' "$lcov"
