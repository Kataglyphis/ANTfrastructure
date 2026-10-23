#!/usr/bin/env bash
# Binary-mode hash separators must match the host and image receipts.
wheelhouse_manifest() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | awk '{print substr($0, 1, 64) "  " substr($0, 67)}')
}
