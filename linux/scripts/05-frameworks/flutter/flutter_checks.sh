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

# `dart format .` is deliberate here and NOT portable to Windows consumers: it
# walks .git/modules, which overruns MAX_PATH there. See Get-ProjectDartFiles
# in windows/scripts/modules/WindowsFormatting.Common.psm1.
info "Checking Dart formatting..."
_run dart format --output=none --set-exit-if-changed .

info "Analyzing..."
_run dart analyze

info "Running tests..."
_run flutter test

info "Flutter checks completed."
