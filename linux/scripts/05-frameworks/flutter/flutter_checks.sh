#!/usr/bin/env bash
set -euo pipefail

# Dart/Flutter equivalent of 02-toolchain/rust/cargo_fmt_clippy.sh + cargo_test.sh.
# Docs: docs/linux-reference.md.
#
# Usage: flutter_checks.sh [--strict <bool>] [--extra-package <dir>]...
#   --strict false  reports failures and continues (default: true)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/logging.sh"
source "$SCRIPT_DIR/../../01-core/platform.sh"
source "$SCRIPT_DIR/../../lib/code-quality.sh"   # code_quality_find_dart_files

STRICT="true"
EXTRA_PACKAGES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT="${2:?--strict needs a value}"; shift 2 ;;
    --extra-package) EXTRA_PACKAGES+=("${2:?--extra-package needs a dir}"); shift 2 ;;
    *) err "flutter_checks.sh: unknown argument: $1"; exit 2 ;;
  esac
done

_run() {
  if is_truthy "$STRICT"; then
    "$@"
  else
    "$@" || warn "flutter_checks: '$*' failed (non-strict, continuing)"
  fi
}

info "Resolving Dart dependencies..."
flutter pub get
for _pkg in ${EXTRA_PACKAGES[@]+"${EXTRA_PACKAGES[@]}"}; do
  info "Resolving dependencies in ${_pkg}..."
  ( cd "$_pkg" && flutter pub get )
done

# Tracked files, never `dart format .`: the CI lanes install the Flutter SDK
# inside the mounted workspace, so a recursive walk reformats the SDK itself.
info "Checking Dart formatting..."
mapfile -t _dart_files < <(code_quality_find_dart_files .)
if [ "${#_dart_files[@]}" -eq 0 ]; then
  # Empty means git could not read the tree (no repo, safe.directory), not
  # "nothing to check" — skipping silently would retire the gate.
  if is_truthy "$STRICT"; then
    err "flutter_checks: no tracked .dart files found; refusing to skip the format gate."
  fi
  warn "flutter_checks: no tracked .dart files found; skipping the format gate (non-strict)."
else
  _run dart format --output=none --set-exit-if-changed "${_dart_files[@]}"
fi

info "Analyzing..."
_run dart analyze

info "Running tests..."
_run flutter test

info "Flutter checks completed."
