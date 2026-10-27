#!/usr/bin/env bash
# Project text must accompany the binary; this does not inventory third-party licenses.

app_packaging_validate_project_license() {
  local source="${1:?license source required}"
  if [[ ! -f "$source" || ! -s "$source" || ! -r "$source" ]] || ! LC_ALL=C grep -q '[^[:space:]]' "$source"; then
    echo "Error: project license is missing, empty or unreadable: $source" >&2
    return 1
  fi
}

app_packaging_stage_project_license() {
  local source="${1:?license source required}" destination="${2:?bundle directory required}"
  app_packaging_validate_project_license "$source" || return $?
  if [[ ! -d "$destination" ]]; then
    echo "Error: license bundle directory not found: $destination" >&2
    return 1
  fi
  install -m 0644 "$source" "$destination/LICENSE"
}
