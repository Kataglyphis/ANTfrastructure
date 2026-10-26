#!/usr/bin/env bash
# layer-audit.py: a file a later layer deletes or replaces is counted as stored-but-dead; live bytes are what the image shows (CON-layer).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
AUDIT="${TESTS_DIR}/../layer-audit.py"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/blobs"

# Two layers, base first: L0 holds a 1000-byte file that L1 deletes and a 10-byte file that L1 replaces.
python3 - "${_work}" <<'PY'
import io
import json
import os
import sys
import tarfile

work = sys.argv[1]
def layer(name, entries):
    path = os.path.join(work, 'blobs', name)
    with tarfile.open(path, 'w:gz') as tar:
        for arc, data in entries:
            info = tarfile.TarInfo(arc); info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return {'digest': 'sha256:' + name, 'size': os.path.getsize(path)}
l0 = layer('l0' * 32, [('opt/a.bin', b'x' * 1000), ('opt/keep.txt', b'y' * 10)])
l1 = layer('l1' * 32, [('opt/.wh.a.bin', b''), ('usr/new.txt', b'z' * 500), ('opt/keep.txt', b'w' * 20)])
history = [
    {'created_by': 'COPY rootfs / # buildkit'},
    {'created_by': 'LABEL kataglyphis.step=android-sdk', 'empty_layer': True},
    {'created_by': 'ARG ANDROID_API=35', 'empty_layer': True},
    {'created_by': 'RUN |12 A=1 B=2 /bin/sh -c bash install.sh # buildkit'},
]
with open(os.path.join(work, 'blobs', 'c0' * 32), 'w') as fh:
    json.dump({'history': history}, fh)
with open(os.path.join(work, 'manifest.json'), 'w') as fh:
    json.dump({'Manifest': {'layers': [l0, l1], 'config': {'digest': 'sha256:' + 'c0' * 32}}}, fh)
with open(os.path.join(work, 'spent.json'), 'w') as fh:
    json.dump({'history': [
        {'created_by': 'LABEL kataglyphis.step=noop', 'empty_layer': True},
        {'created_by': 'RUN /bin/sh -c true # buildkit', 'empty_layer': True},
        {'created_by': 'COPY a /a # buildkit'},
        {'created_by': 'COPY b /b # buildkit'}]}, fh)
PY

t_case "the live image holds the newest versions only; deleted and replaced bytes are reported as dead"
out="$(python3 "${AUDIT}" --json "${_work}/manifest.json" "${_work}/blobs")"
t_assert_eq "520" "$(printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["live_bytes"])')"
t_assert_eq "1000" "$(printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deleted_bytes"])')"
t_assert_eq "10" "$(printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["replaced_bytes"])')"

t_case "--find names the layer that holds a path"
out="$(python3 "${AUDIT}" --find usr/ "${_work}/manifest.json" "${_work}/blobs")"
t_assert_contains "${out}" "usr/ in layer 01: usr/new.txt"

t_case "a step label names the next RUN's layer, through an ARG, and no layer after it"
out="$(python3 "${AUDIT}" "${_work}/manifest.json" "${_work}/blobs")"
t_assert_contains "${out}" "whiteouts=0 step=COPY rootfs / # buildkit"
t_assert_contains "${out}" "whiteouts=1 step=android-sdk"

t_case "an empty RUN spends its label, so the COPY after it is not misnamed"
out="$(python3 "${AUDIT}" --config "${_work}/spent.json" "${_work}/manifest.json" "${_work}/blobs")"
t_assert_contains "${out}" "whiteouts=0 step=COPY a /a # buildkit"
t_assert_contains "${out}" "whiteouts=1 step=COPY b /b # buildkit"

t_summary
