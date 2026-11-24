#!/usr/bin/env bash
# shellcheck shell=bash
# See docs/onnxruntime-single-source.md § Source pins and fork fallback

_ORT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ort_source_say() { printf '[ort-source] %s\n' "$*" >&2; }

# Usage: <name>; prints "tag|commit|fallbacks" for exactly one pinned name.
ort_source_pin() {
  local name="$1" file="${_ORT_SOURCE_DIR}/source-pins.txt" found="" count=0 pin_name tag commit fallbacks
  if [ ! -f "$file" ]; then
    _ort_source_say "pin file missing: $file"
    return 1
  fi
  while IFS='|' read -r pin_name tag commit fallbacks; do
    case "$pin_name" in '' | '#'*) continue ;; esac
    [ "$pin_name" = "$name" ] || continue
    count=$((count + 1))
    found="${tag}|${commit}|${fallbacks}"
  done < "$file"
  if [ "$count" -ne 1 ]; then
    _ort_source_say "expected one pin for $name in $file, found $count"
    return 1
  fi
  if ! [[ "${found#*|}" =~ ^[0-9a-f]{40}\| ]]; then
    _ort_source_say "pin for $name lacks a full 40-character commit"
    return 1
  fi
  printf '%s\n' "$found"
}

# Usage: <deps.txt> <dependency> <pin-name>; deps.txt columns are name;url;commit.
ort_source_dep_url() {
  local deps="$1" dependency="$2" pin_name="$3" pin commit line dep_name url dep_commit
  pin="$(ort_source_pin "$pin_name")" || return 1
  commit="${pin#*|}"
  commit="${commit%%|*}"
  line="$(grep -E "^${dependency};" "$deps" || true)"
  if [ -z "$line" ] || [ "$(printf '%s\n' "$line" | wc -l)" -ne 1 ]; then
    _ort_source_say "expected one $dependency row in $deps"
    return 1
  fi
  IFS=';' read -r dep_name url dep_commit <<< "$line"
  if [ "$dep_commit" != "$commit" ]; then
    _ort_source_say "$deps pins $dep_name at ${dep_commit:-<none>} but source-pins.txt has $commit"
    return 1
  fi
  printf '%s\n' "$url"
}

_ort_source_by_commit() {
  local url="$1" commit="$2" dir="$3" tag="$4"
  rm -rf "$dir"
  git init -q "$dir" \
    && git -C "$dir" remote add origin "$url" \
    && git -C "$dir" fetch -q --depth 1 origin "$commit" \
    && git -C "$dir" checkout -q --detach FETCH_HEAD \
    || return 1
  if [ "$tag" != "-" ]; then
    git -C "$dir" tag "$tag" HEAD || return 1
  fi
}

_ort_source_verified() {
  local name="$1" commit="$2" dir="$3" url="$4" head
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  if [ "$head" != "$commit" ]; then
    _ort_source_say "$name from $url is at ${head:-<unreadable>}, not the pinned $commit"
    return 1
  fi
  _ort_source_say "$name $commit verified from $url"
}

# Usage: <name> <tag-or-> <primary-url> <dir>; a moved primary tag is fatal and never falls back.
ort_source_fetch() {
  local name="$1" version="$2" primary="$3" dir="$4" pin tag commit fallbacks attempt url fetched=0
  local -a mirrors=()
  pin="$(ort_source_pin "$name")" || return 1
  IFS='|' read -r tag commit fallbacks <<< "$pin"
  if [ "$tag" != "$version" ]; then
    _ort_source_say "$name pin is for $tag but the build asks for $version; pin the new tag's commit in source-pins.txt"
    return 1
  fi
  for attempt in 1 2 3; do
    rm -rf "$dir"
    if [ "$tag" = "-" ]; then
      _ort_source_by_commit "$primary" "$commit" "$dir" "$tag" && fetched=1
    else
      git clone -q --depth 1 --branch "$tag" "$primary" "$dir" && fetched=1
    fi
    [ "$fetched" -eq 0 ] || break
    _ort_source_say "$name primary fetch attempt $attempt/3 from $primary failed"
    [ "$attempt" -eq 3 ] || sleep 10
  done
  if [ "$fetched" -eq 1 ]; then
    _ort_source_verified "$name" "$commit" "$dir" "$primary"
    return $?
  fi
  IFS=' ' read -r -a mirrors <<< "$fallbacks"
  for url in "${mirrors[@]}"; do
    _ort_source_say "$name falling back to $url at $commit"
    if _ort_source_by_commit "$url" "$commit" "$dir" "$tag"; then
      _ort_source_verified "$name" "$commit" "$dir" "$url"
      return $?
    fi
  done
  rm -rf "$dir"
  _ort_source_say "$name $commit is unavailable from $primary and ${#mirrors[@]} fallback repositories"
  return 1
}
