#!/usr/bin/env bash
# ort-web-parity-ci.sh <report dir> [--jsep]: stage the image's ORT Web builds with their bundles, fetch DEIM and the photo, report each build. See docs/docs-sites.md#detector-parity-of-the-ort-web-builds
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:?usage: ort-web-parity-ci.sh <report dir> [--jsep]}"
shift
jsep=()
case "${1:-}" in
  '') ;;
  --jsep) jsep=(--jsep) ;;
  *) printf 'ort-web-parity-ci.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
esac
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
python3 -I "${root}/linux/scripts/lib/stage-ort-web.py" --out "${work}/site" ${jsep[@]+"${jsep[@]}"}
python3 -I "${root}/linux/scripts/lib/fetch-data-lock.py" --lock "${root}/linux/scripts/lib/ort-web-parity.lock" \
  --dest "${work}/data" --cache "${work}/cache"
tar -xzf "${work}/data/deim_dfine_n_coco.contract.tar.gz" -C "${work}/data" contracts/fixtures/two_cats.jpg
python3 -I "${root}/shared/python/ort_web_parity.py" --site "${work}/site" --model "${work}/data/deim_dfine_n_coco.onnx" \
  --image "${work}/data/contracts/fixtures/two_cats.jpg" --out "${out}" ${jsep[@]+"${jsep[@]}"}
