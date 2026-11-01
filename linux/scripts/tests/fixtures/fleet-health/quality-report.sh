#!/usr/bin/env bash
# Stands in for quality-report.sh: copies the case's record for this checkout, its SHA filled in.
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "${root}/logs/code-quality"
sed "s/@SHA@/$(git -C "${root}" rev-parse HEAD)/g" "${FAKE_MEASUREMENTS}/$(basename "${root}").json" \
  > "${root}/logs/code-quality/measurements.json"
