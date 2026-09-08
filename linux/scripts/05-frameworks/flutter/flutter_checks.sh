#!/usr/bin/env bash
set -euo pipefail

# Dart/Flutter equivalent of 02-toolchain/rust/cargo_fmt_clippy.sh + cargo_test.sh.
# Docs: docs/code-quality-tooling.md#dart-file-enumeration
#
# Usage: flutter_checks.sh [--strict <bool>] [--extra-package <dir>]...
#   --strict false  reports failures and continues (default: true)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/logging.sh"
source "$SCRIPT_DIR/../../01-core/platform.sh"
source "$SCRIPT_DIR/../../lib/code-quality.sh"   # code_quality_find_tracked_files

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

# ---------------------------------------------------------------------------
# pubspec structure
# ---------------------------------------------------------------------------
# A `fonts:`/`assets:` key at COLUMN 0 is a top-level pubspec key. Flutter reads
# only the ones nested under `flutter:` and drops a misplaced block in silence:
# both Flutter apps in this fleet shipped a column-0 `fonts:` block, so
# FontManifest.json carried no custom face at all and every `fontFamily:` fell
# back to the platform default. Nothing caught it, hence this gate.
# The second half is the same failure one level down - a declared path that
# resolves to nothing bundles nothing, just as quietly.

# Prints every tracked pubspec.yaml under the given root, one per line. The
# exclusions are code_quality_find_tracked_files' own -- rust_builder/ included,
# which this gate used to miss -- so the pubspec gate and the Dart formatter and
# analyzer grade exactly the same set of packages.
_find_pubspecs() {
  code_quality_find_tracked_files "${1:-.}" 'pubspec.yaml' '*/pubspec.yaml'
}

# Prints every asset path a pubspec declares: the `assets:` list entries plus
# each font face's `- asset:` value. Comments and quotes are stripped.
_pubspec_declared_paths() {
  awk '
    /^[[:space:]]*#/                       { next }
    /^[[:space:]]*-[[:space:]]*asset:/     { sub(/^[^:]*:[[:space:]]*/, ""); print; next }
    /^[[:space:]]*assets:[[:space:]]*$/    { in_list = 1; next }
    in_list && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
    in_list && NF                          { in_list = 0 }
  ' "$1" | sed -e 's/[[:space:]]*#.*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]*$//'
}

# Fails (returns 1) on a column-0 `assets:`/`fonts:` key, or on a declared path
# that bundles nothing. Every offender is named; the caller decides strictness.
_check_pubspec_structure() {
  local pubspec="$1"
  local dir path target rc=0
  dir="$(dirname "$pubspec")"

  if grep -nE '^(assets|fonts):' "$pubspec" >&2; then
    fail "${pubspec}: the key(s) above sit at column 0 - a top-level pubspec key Flutter ignores. Nest them under 'flutter:'."
    rc=1
  fi

  # The path check below reads the block form only. An inline flow sequence is
  # legal YAML, so refuse it by name rather than walk past it unchecked.
  if grep -nE '^[[:space:]]*assets:[[:space:]]*\[' "$pubspec" >&2; then
    fail "${pubspec}: inline 'assets: [...]' above; this gate reads the block form only. Rewrite it as a block list so its paths are checked."
    rc=1
  fi

  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    case "${path}" in
      packages/*)
        warn "${pubspec}: '${path}' points into another package; this gate does not resolve it."
        continue
        ;;
    esac
    target="${dir}/${path}"
    if [ "${path}" != "${path%/}" ]; then
      if [ -n "$(find "${target}" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]; then
        continue
      fi
    elif [ -e "${target}" ]; then
      continue
    fi
    fail "${pubspec} declares '${path}', which bundles nothing (no such file, or the directory holds none)."
    rc=1
  done < <(_pubspec_declared_paths "${pubspec}")

  return "${rc}"
}

info "Checking pubspec structure..."
mapfile -t _pubspecs < <(_find_pubspecs .)
for _pkg in ${EXTRA_PACKAGES[@]+"${EXTRA_PACKAGES[@]}"}; do
  mapfile -t -O "${#_pubspecs[@]}" _pubspecs < <(_find_pubspecs "$_pkg")
done
if [ "${#_pubspecs[@]}" -eq 0 ]; then
  # Same reasoning as the format gate below: empty means git could not read the
  # tree, not "nothing to check" - skipping silently would retire the gate.
  if is_truthy "$STRICT"; then
    err "flutter_checks: no tracked pubspec.yaml found; refusing to skip the pubspec structure gate."
  fi
  warn "flutter_checks: no tracked pubspec.yaml found; skipping the pubspec structure gate (non-strict)."
else
  for _pubspec in "${_pubspecs[@]}"; do
    _run _check_pubspec_structure "$_pubspec"
  done
fi

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
