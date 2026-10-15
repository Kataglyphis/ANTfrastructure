#!/usr/bin/env bash
# publish-github-release.sh: release v<version> at HEAD with a directory's files, a SHA256SUMS and its CHANGELOG section; docs/branch-and-release-strategy.md#the-release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_UTIL="${SCRIPT_DIR}/../02-toolchain/rust/version_util.sh"

usage() {
  printf 'usage: publish-github-release.sh --version-file FILE --changelog FILE --name NAME (--check | --assets DIR)\n' >&2
  exit 2
}

# The section headed "## <version>" or "## [<version>]", then a "+build", " - date" or "]", up to the next "## ".
changelog_section() {
  awk -v v="$1" '
    /^## / {
      if (found) exit
      h = substr($0, 4)
      if (substr(h, 1, 1) == "[") h = substr(h, 2)
      rest = substr(h, length(v) + 1, 1)
      found = (index(h, v) == 1 && (rest == "" || rest == "+" || rest == " " || rest == "]"))
      next
    }
    found { print }
  ' "$2"
}

# Every merge into main is a release, so a version is released once; any other gh error is not "not released".
refuse_released() {
  local view
  if view="$(gh release view "$1" --json tagName 2>&1)"; then
    printf '%s is already released: raise the version in %s and give it a CHANGELOG section\n' "$1" "$2" >&2
    exit 1
  elif [[ "$view" != *"not found"* ]]; then
    printf 'could not ask GitHub about %s: %s\n' "$1" "$view" >&2
    exit 1
  fi
}

# The cameras' and installers' updaters check a download against SHA256SUMS before they use it.
publish() {
  local tag="$1" title="$2" notes="$3" dir="$4" notes_file packages
  rm -f "${dir}/SHA256SUMS"
  shopt -s nullglob
  packages=("${dir}"/*)
  if [ "${#packages[@]}" -eq 0 ]; then
    printf 'no files in %s\n' "$dir" >&2
    exit 1
  fi
  (cd "$dir" && sha256sum -- * > SHA256SUMS)
  notes_file="$(mktemp)"
  printf '%s\n' "$notes" > "$notes_file"
  gh release create "$tag" --target "$(git rev-parse HEAD)" --title "$title" \
    --notes-file "$notes_file" "${packages[@]}" "${dir}/SHA256SUMS"
  rm -f "$notes_file"
}

version_file="" changelog="" name="" assets="" check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version-file) version_file="${2:-}"; shift 2 ;;
    --changelog) changelog="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    --assets) assets="${2:-}"; shift 2 ;;
    --check) check=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$version_file" ] && [ -n "$changelog" ] && [ -n "$name" ] || usage
[ "$check" = 1 ] || [ -n "$assets" ] || usage

version="$(bash "$VERSION_UTIL" --file-version "$version_file" 2>/dev/null)" || {
  printf '%s states no version\n' "$version_file" >&2
  exit 1
}
tag="v${version}"
notes="$(changelog_section "$version" "$changelog")"
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  printf '%s has no section for %s\n' "$changelog" "$version" >&2
  exit 1
fi
# GitHub refuses a release body over 125000 characters, and only at the very end of a release run.
if [ "${#notes}" -gt 125000 ]; then
  printf "%s's section for %s has %d characters, over GitHub's 125000: shorten it\n" "$changelog" "$version" "${#notes}" >&2
  exit 1
fi
refuse_released "$tag" "$version_file"
if [ "$check" = 1 ]; then
  printf '%s is not released yet and has its CHANGELOG section\n' "$tag"
  exit 0
fi
publish "$tag" "${name} ${version}" "$notes" "$assets"
