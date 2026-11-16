#!/usr/bin/env bash
# Explicit application selection keeps executable helpers out of generated launchers.
app_packaging_detect_bundle_binary() {
  local bundle_dir="${1:?bundle_dir required}"
  if [[ ! -d "$bundle_dir" ]]; then
    echo "Error: bundle directory not found: $bundle_dir" >&2
    return 1
  fi

  local declared="${APP_PACKAGING_BINARY_NAME:-}"
  if [[ -n "$declared" ]]; then
    if [[ ! "$declared" =~ ^[a-zA-Z0-9_.+-]+$ || "$declared" == . || "$declared" == .. ]]; then
      printf 'Error: declared bundle executable must be a portable basename: %s\n' "$declared" >&2
      return 1
    fi
    if [[ ! -f "$bundle_dir/$declared" || ! -x "$bundle_dir/$declared" || -L "$bundle_dir/$declared" ]]; then
      printf 'Error: declared bundle executable is missing, linked or not executable: %s\n' "$declared" >&2
      return 1
    fi
    printf '%s\n' "$declared"
    return 0
  fi

  local binary=""
  while IFS= read -r candidate; do
    local base
    base="$(basename "$candidate")"
    # bundle-loader.sh --beside leaves the loader (ld-linux-*.so.N) and <name>.bin beside the launcher.
    if [[ "$base" == *.so || "$base" == *.so.* || "$base" == *.sh || "$base" == *.bin ]]; then
      continue
    fi
    binary="$base"
    break
  done < <(find "$bundle_dir" -mindepth 1 -maxdepth 1 -type f -executable | sort)

  if [[ -z "$binary" ]]; then
    echo "Error: could not detect executable in $bundle_dir" >&2
    return 1
  fi

  echo "$binary"
}
