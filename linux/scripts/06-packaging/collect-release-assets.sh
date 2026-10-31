#!/usr/bin/env bash
# collect-release-assets.sh [options] <artifacts dir> <out dir>: the lanes' uploads as one flat directory of release files; docs/branch-and-release-strategy.md#collecting-the-release-files
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: collect-release-assets.sh [options] <artifacts dir> <out dir>
  --version V                         the value of {version}
  --skip UPLOAD_GLOB                  an upload that is no deliverable
  --include PATH_GLOB                 collect a file whose <upload>/<path> matches
  --exclude PATH_GLOB                 never collect a file whose <upload>/<path> matches
  --only-from PATH_GLOB=UPLOAD_GLOB   such a file ships only from these uploads
  --rename PATH_GLOB=NAME             collect such a file as NAME
  --flatpak-arch-from-suffix          --rename '*.flatpak={stem}-{machine}.flatpak'
  --zip UPLOAD_GLOB[/DIR]=NAME        ship the upload's folder, or its DIR, as one zip
  --unpack UPLOAD_GLOB                collect from the contents of the upload's tarballs
  --expect NAME                       the release must carry NAME
  --strict                            an upload neither skipped nor collected from fails
  --lone-upload NAME                  the artifacts dir is the one upload NAME, unless it holds a NAME folder
  --options FILE                      more options, one per line, globs unquoted
Globs are case patterns, so * crosses /. NAME takes {version}, {stem} (the file's name
without its last extension), and {arch} and {machine} from the upload's name:
x64 x86_64, arm64 aarch64, riscv64 riscv64. A docs site's upload (*-docs-site, docs-site-*)
and uploads named with candidate, unverified or inventory-only are always skipped
regardless of letter case. User-supplied skip globs remain case-sensitive.
USAGE
  exit 2
}

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../01-core/logging.sh"

VERSION="" STRICT=0 GAVE=0 OUT="" SCRATCH="" LONE=""
SKIP=('*-docs-site' 'docs-site-*')
# Draft GPU outputs must not be collected by broad release file globs.
DRAFT_SKIP=('*candidate*' '*unverified*' '*inventory-only*')
INCLUDE=() EXCLUDE=() ONLY_FROM=() RENAME=() ZIP=() UNPACK=() EXPECT=() POSITIONAL=()

add_to() {
  local -n _list="$1"
  _list+=("$2")
}

parse_args() {
  local list
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip | --include | --exclude | --only-from | --rename | --zip | --unpack | --expect)
        [ $# -ge 2 ] || die "$1 needs a value"
        list="${1#--}"
        list="${list//-/_}"
        add_to "${list^^}" "$2"
        shift 2
        ;;
      --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
      --options) [ $# -ge 2 ] || die "--options needs a file"; read_options "$2"; shift 2 ;;
      --strict) STRICT=1; shift ;;
      --lone-upload) [ $# -ge 2 ] || die "--lone-upload needs a name"; LONE="$2"; shift 2 ;;
      --flatpak-arch-from-suffix) RENAME+=('*.flatpak={stem}-{machine}.flatpak'); shift ;;
      -h | --help) usage ;;
      -*) die "unknown option $1" ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
}

# read_options <file>: each line is one option and its value; blank and # lines are skipped.
read_options() {
  local line opt value args=()
  [ -f "$1" ] || die "no options file $1"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    read -r opt value <<< "$line" || true
    case "$opt" in '' | '#'*) continue ;; --*) ;; *) die "$1: '${line}' is not an option" ;; esac
    args+=("$opt")
    if [ -n "$value" ]; then args+=("$value"); fi
  done < "$1"
  parse_args "${args[@]}"
}

# A quoted glob in an options file would match nothing, silently.
check_rules() {
  local rule
  for rule in "${ONLY_FROM[@]}" "${RENAME[@]}" "${ZIP[@]}"; do
    case "$rule" in ?*=?*) ;; *) die "a rule needs GLOB=VALUE: ${rule}" ;; esac
  done
  for rule in "${SKIP[@]}" "${INCLUDE[@]}" "${EXCLUDE[@]}" "${ONLY_FROM[@]}" "${RENAME[@]}" "${ZIP[@]}" "${UNPACK[@]}" "${EXPECT[@]}"; do
    case "$rule" in \'* | \"*) die "write ${rule} unquoted" ;; esac
  done
}

glob_match() {
  # shellcheck disable=SC2254
  case "$1" in $2) return 0 ;; esac
  return 1
}

# any_match <text> <glob>...
any_match() {
  local text="$1" glob
  shift
  for glob in "$@"; do
    if glob_match "$text" "$glob"; then return 0; fi
  done
  return 1
}

# upload_arch <upload>: the last of x64, arm64 and riscv64 among the name's dash-separated words.
upload_arch() {
  local word arch="" words=()
  IFS='-' read -r -a words <<< "$1"
  for word in "${words[@]}"; do
    case "$word" in x64 | arm64 | riscv64) arch="$word" ;; esac
  done
  [ -n "$arch" ] || return 1
  printf '%s' "$arch"
}

# render <template> <upload> <file name>: the template with its placeholders filled in.
render() {
  local name="$1" arch="" machine=""
  case "$name" in
    *'{arch}'* | *'{machine}'*)
      arch="$(upload_arch "$2")" || die "no arch in '${2}' for ${1}"
      case "$arch" in x64) machine=x86_64 ;; arm64) machine=aarch64 ;; *) machine="$arch" ;; esac
      ;;
  esac
  case "$name" in *'{version}'*) [ -n "$VERSION" ] || die "${1} names {version}: pass --version" ;; esac
  name="${name//'{version}'/$VERSION}"
  name="${name//'{arch}'/$arch}"
  name="${name//'{machine}'/$machine}"
  name="${name//'{stem}'/${3%.*}}"
  case "$name" in '' | */*) die "${1} makes '${name}', not a file name" ;; esac
  printf '%s' "$name"
}

# only_from_allows <path> <upload>: false when an --only-from rule names the file and none names the upload.
only_from_allows() {
  local rule named=0
  for rule in "${ONLY_FROM[@]}"; do
    glob_match "$1" "${rule%%=*}" || continue
    if glob_match "$2" "${rule#*=}"; then return 0; fi
    named=1
  done
  return "$named"
}

# release_name <path> <upload>: the name the file ships under, or nothing.
release_name() {
  local rule
  if any_match "$1" "${EXCLUDE[@]}" || ! only_from_allows "$1" "$2"; then return 0; fi
  for rule in "${RENAME[@]}"; do
    if glob_match "$1" "${rule%%=*}"; then
      render "${rule#*=}" "$2" "${1##*/}"
      return 0
    fi
  done
  if any_match "$1" "${INCLUDE[@]}"; then printf '%s' "${1##*/}"; fi
}

# put <file> <name>: one release file; a second one of the same name would silently replace the first.
put() {
  [ ! -e "${OUT}/$2" ] || die "two artifacts carry $2"
  cp "$1" "${OUT}/$2"
  GAVE=1
}

zip_rules() {
  local dir="$1" upload="$2" rule left folder name
  for rule in "${ZIP[@]}"; do
    left="${rule%%=*}"
    glob_match "$upload" "${left%%/*}" || continue
    folder="$dir"
    if [ "$left" != "${left%%/*}" ]; then folder="${dir}/${left#*/}"; fi
    [ -d "$folder" ] || die "upload ${upload} has no ${left#*/} to zip"
    name="$(render "${rule#*=}" "$upload" "")" || exit 1
    [ ! -e "${OUT}/${name}" ] || die "two artifacts carry ${name}"
    (cd "$folder" && zip -qr "${OUT}/${name}" .)
    GAVE=1
  done
}

# unpacked <dir> <upload>: a scratch copy of the upload, each tarball in it replaced by its contents.
unpacked() {
  local copy="${SCRATCH}/$2" tarball
  cp -R "$1" "$copy"
  while IFS= read -r -d '' tarball; do
    tar -xzf "$tarball" -C "$(dirname "$tarball")"
    rm -f "$tarball"
  done < <(find "$copy" -type f \( -name '*.tar.gz' -o -name '*.tgz' \) -print0)
  printf '%s' "$copy"
}

collect_upload() {
  local dir="$1" upload="$2" file name
  if any_match "$upload" "${UNPACK[@]}"; then
    dir="$(unpacked "$dir" "$upload")" || exit 1
  fi
  zip_rules "$dir" "$upload"
  while IFS= read -r -d '' file; do
    name="$(release_name "${upload}/${file#"${dir}"/}" "$upload")" || exit 1
    if [ -n "$name" ]; then put "$file" "$name"; fi
  done < <(find "$dir" -type f -print0 | LC_ALL=C sort -z)
}

check_expected() {
  local expected name
  for expected in "${EXPECT[@]}"; do
    name="$(render "$expected" "" "")" || exit 1
    [ -e "${OUT}/${name}" ] || die "the release would lack ${name}"
  done
}

# collect_one <dir> <upload>: one upload, unless it is skipped; --strict fails one that gives nothing.
collect_one() {
  local dir="$1" upload="$2" draft_name
  draft_name="$(LC_ALL=C; printf '%s' "${upload,,}")"
  if any_match "$upload" "${SKIP[@]}" || any_match "$draft_name" "${DRAFT_SKIP[@]}"; then return 0; fi
  GAVE=0
  collect_upload "$dir" "$upload"
  [ "$GAVE" = 1 ] || [ "$STRICT" = 0 ] || die "upload ${upload} is neither collected nor skipped: decide in the release's collect options"
}

main() {
  local dir artifacts
  parse_args "$@"
  [ "${#POSITIONAL[@]}" -eq 2 ] || usage
  check_rules
  artifacts="${POSITIONAL[0]}"
  [ -d "$artifacts" ] || die "no artifacts directory ${artifacts}"
  mkdir -p "${POSITIONAL[1]}"
  # Absolute, because the zips are made from inside each folder.
  OUT="$(cd "${POSITIONAL[1]}" && pwd)"
  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "${SCRATCH}"' EXIT
  # download-artifact extracts a lone upload straight into its path, without the upload's folder.
  if [ -n "$LONE" ] && [ ! -d "${artifacts}/${LONE}" ]; then
    collect_one "$artifacts" "$LONE"
  else
    [ -z "$(find "$artifacts" -mindepth 1 -maxdepth 1 -type f -print -quit)" ] ||
      die "files lie directly in ${artifacts}, outside any upload: name the lone upload with --lone-upload"
    for dir in "$artifacts"/*/; do
      [ -d "$dir" ] || continue
      collect_one "${dir%/}" "$(basename "$dir")"
    done
  fi
  check_expected
  [ -n "$(ls -A "$OUT")" ] || die "no packages under ${artifacts}"
  ls -1 "$OUT"
}

main "$@"
