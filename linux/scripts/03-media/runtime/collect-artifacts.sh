#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# WHEELS_DIR (and the media path env) come from the canonical media-env.sh.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/media-env.sh"

collect_component_wheels() {
  local source_dir="$1"

  [ -d "${source_dir}" ] || return 0
  mv "${source_dir}"/*.whl "${WHEELS_DIR}/" 2>/dev/null || true
}

# The chain ORT wheel's native members, hashed before the wheel leaves its prefix: the runtime image
# never holds the wheel, so the ORT census (06-packaging/check-ort-provenance.sh) reads this list.
write_ort_wheel_manifest() {
  local prefix="$1" versions_env="${2:-/opt/scripts/core/versions.env}" ver="${ONNXRUNTIME_VERSION:-}"
  [ -d "${prefix}/wheels" ] || return 0
  # Pinned to this build's ORT version: any other wheel in the prefix must not become chain truth.
  if [ -z "${ver}" ] && [ -f "${versions_env}" ]; then ver="$(sed -n '/^ONNXRUNTIME_VERSION=/{s///p;q;}' "${versions_env}")"; fi
  ver="${ver%$'\r'}"
  if [ -z "${ver}" ]; then
    echo "ERROR: write_ort_wheel_manifest: no ONNXRUNTIME_VERSION (env or ${versions_env}) to pin the chain wheel to" >&2
    return 1
  fi
  python3 - "${prefix}" "${ver#v}" <<'PY'
import hashlib
import os
import re
import sys
import zipfile

prefix = sys.argv[1]
pin = re.compile(r"onnxruntime(?:[_-](?!genai)[a-z0-9]+)?-" + re.escape(sys.argv[2]) + r"(?:\+[A-Za-z0-9.]+)?-.*\.whl$")
rows = []
for name in sorted(os.listdir(os.path.join(prefix, "wheels"))):
    if not pin.match(name):
        continue
    with zipfile.ZipFile(os.path.join(prefix, "wheels", name)) as zf:
        for info in zf.infolist():
            if re.search(r"\.so(?:\.[0-9]+)*$", info.filename):
                rows.append("%s  %s!%s\n" % (hashlib.sha256(zf.read(info)).hexdigest(), name, info.filename))
with open(os.path.join(prefix, "ort-provenance.sha256"), "w", encoding="utf-8") as fh:
    fh.writelines(rows)
print("ort-provenance.sha256: %d chain wheel member(s) under %s" % (len(rows), prefix))
PY
}

write_ort_wheel_manifest /usr/local/lib/onnxruntime-cpu
write_ort_wheel_manifest /usr/local/lib/onnxruntime-gpu

wheel_source_dirs=(
  /usr/local/lib/onnxruntime-cpu/wheels
  /usr/local/lib/onnxruntime-genai/wheels
  /usr/local/lib/onnxruntime-gpu/wheels
  /opt/opencv5/wheels
  /opt/app-wheels
  /opt/litert-wheels
  /opt/tvm-wheels
  /opt/libcamera/wheels
)

mkdir -p "${WHEELS_DIR}"

for wheel_source_dir in "${wheel_source_dirs[@]}"; do
  collect_component_wheels "${wheel_source_dir}"
done

rm -rf "${wheel_source_dirs[@]}"
