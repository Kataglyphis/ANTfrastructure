#!/usr/bin/env bash
# mirror-app-models.py over file:// locks and a seeded cache: the models/<sha256>/ tree, the web manifest and every refusal. See docs/docs-sites.md#mirroring-an-apps-models
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MIRROR="${TESTS_DIR}/../lib/mirror-app-models.py"
PY="${PREFLIGHT_PYTHON:-python3}"

t_skip_unless "a POSIX python3" t_posix_python
t_private_tmpdir
w="$(t_mktemp -d)"
rel="${w}/release"
mkdir -p "${rel}" "${w}/repo/locks"
printf 'onnx-bytes' > "${rel}/det.onnx"
printf 'Apache-2.0 text' > "${rel}/det.LICENSE"
printf 'notice text' > "${rel}/det.NOTICE"
printf 'second-model' > "${rel}/seg.onnx"
printf 'seg license' > "${rel}/seg.LICENSE"
printf 'seg notice' > "${rel}/seg.NOTICE"
printf 'packed' > "${rel}/text.tar.xz"

sha() { sha256sum < "$1" | cut -c1-64; }
# rows <url prefix> <file>...: the lock rows of those release files, each URL the prefix and the name.
rows() { local prefix="$1"; shift; (cd "${rel}" && sha256sum -- "$@") | awk -v p="${prefix}" '{ print $1 "  " $2 "  " p $2 }'; }
# lock <name> <file>...: a lock of those release files below the fixture repository.
lock() { local name="$1"; shift; { printf '# sha256 file url\n'; rows "file://${rel}/" "$@"; } > "${w}/repo/locks/${name}"; }
lock models.lock det.onnx det.LICENSE det.NOTICE text.tar.xz
lock seg.lock seg.onnx seg.LICENSE seg.NOTICE
# app <name>: a fresh app directory, as the web build leaves it.
app() { app_dir="${w}/apps/$1"; rm -rf "${app_dir}"; mkdir -p "${app_dir}"; printf '<html></html>' > "${app_dir}/index.html"; }
mirror() { (cd "${w}/repo" && t_logged "${w}/log" "${PY}" -I "${MIRROR}" --out "${app_dir}" --cache "${w}/cache" "$@"); }
mf() { t_json "${app_dir}/models/manifest.json" "$1"; }
# untouched: no models/ and no work directory are left in the app after a refusal.
untouched() { t_assert_eq "index.html" "$(ls -A "${app_dir}")" "a refusal writes nothing"; }

t_case "a model and its LICENSE and NOTICE land at models/<sha256>/<file>, each under its own hash"
app ok
t_assert_ok mirror --model locks/models.lock det.onnx
t_assert_eq onnx-bytes "$(cat "${app_dir}/models/$(sha "${rel}/det.onnx")/det.onnx" 2>&1)"
t_assert_eq "Apache-2.0 text" "$(cat "${app_dir}/models/$(sha "${rel}/det.LICENSE")/det.LICENSE" 2>&1)"
t_assert_eq "notice text" "$(cat "${app_dir}/models/$(sha "${rel}/det.NOTICE")/det.NOTICE" 2>&1)"
t_assert_eq 4 "$(find "${app_dir}/models" -type f | wc -l | tr -d ' ')" "the three files and the manifest, never the archive beside them"
t_assert_eq 755 "$(stat -c %a "${app_dir}/models")" "mkdtemp makes it 0700, and every reader of the site must enter it"
t_assert_contains "$(cat "${w}/log")" "MODEL-MIRROR OK: det.onnx -> models/$(sha "${rel}/det.onnx")/det.onnx with 2 license texts"

t_case "the manifest names file, path, SHA-256, size, license texts and the lock row of each file"
t_assert_eq 1 "$(mf "m['schema_version']")"
t_assert_eq "det det.onnx models/$(sha "${rel}/det.onnx")/det.onnx $(sha "${rel}/det.onnx") 10" \
  "$(mf "' '.join(str(m['models'][0][k]) for k in ('name', 'file', 'path', 'sha256', 'size'))")"
t_assert_eq "locks/models.lock 2 file://${rel}/det.onnx" "$(mf "' '.join(str(m['models'][0]['lock'][k]) for k in ('path', 'line', 'url'))")" \
  "the lock's path in the repository, never the runner's, and the row's line"
t_assert_eq "det.LICENSE models/$(sha "${rel}/det.LICENSE")/det.LICENSE 15 3 | det.NOTICE models/$(sha "${rel}/det.NOTICE")/det.NOTICE 11 4" \
  "$(mf "' | '.join(f\"{t['file']} {t['path']} {t['size']} {t['lock']['line']}\" for t in m['models'][0]['licenses'])")"
t_assert_eq None "$(mf "m['models'][0]['release']")" "a file:// row comes from no release"

t_case "every manifest hash and size is the mirrored file's own"
t_assert_eq "" "$("${PY}" -I - "${app_dir}" <<'PY'
import hashlib
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
for model in json.loads((out / "models/manifest.json").read_text())["models"]:
    for entry in (model, *model["licenses"]):
        data = (out / entry["path"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["sha256"] or len(data) != entry["size"]:
            print("differs:", entry["path"])
PY
)"

t_case "a ModelANT release row names the release; the cache serves it without a download"
mkdir -p "${w}/cache"
for f in det.onnx det.LICENSE det.NOTICE; do cp "${rel}/${f}" "${w}/cache/$(sha "${rel}/${f}")-${f}"; done
rows https://github.com/Kataglyphis/ModelANT/releases/download/det-v2/ det.onnx det.LICENSE det.NOTICE > "${w}/repo/locks/release.lock"
app release
t_assert_ok mirror --model locks/release.lock det.onnx
t_assert_eq "{'repository': 'Kataglyphis/ModelANT', 'tag': 'det-v2'}" "$(mf "m['models'][0]['release']")"

t_case "models of two locks share one tree and one manifest, in the order given"
app two
t_assert_ok mirror --model locks/seg.lock seg.onnx --model locks/models.lock det.onnx
t_assert_eq "seg.onnx locks/seg.lock det.onnx locks/models.lock" "$(mf "' '.join(f\"{x['file']} {x['lock']['path']}\" for x in m['models'])")"

t_case "bytes that differ from the lock are refused, and nothing is written"
app wrong
{ printf '%s  det.onnx  file://%s/seg.onnx\n' "$(sha "${rel}/det.onnx")" "${rel}"; rows "file://${rel}/" det.LICENSE det.NOTICE; } > "${w}/repo/locks/wrong.lock"
t_assert_rc 1 mirror --cache "${w}/empty-cache" --model locks/wrong.lock det.onnx
t_assert_contains "$(cat "${w}/log")" "the lock says $(sha "${rel}/det.onnx")"
untouched

t_case "an existing models/ is refused and kept as it was"
app existing
mkdir -p "${app_dir}/models"
printf 'old' > "${app_dir}/models/manifest.json"
t_assert_rc 1 mirror --model locks/models.lock det.onnx
t_assert_contains "$(cat "${w}/log")" "models exists"
t_assert_eq old "$(cat "${app_dir}/models/manifest.json")"

t_case "a model whose lock lacks its LICENSE or its NOTICE is refused, naming the text"
lock nolicense.lock det.onnx det.NOTICE
app nolicense
t_assert_rc 1 mirror --model locks/nolicense.lock det.onnx
t_assert_contains "$(cat "${w}/log")" "has no det.LICENSE; a model never ships without its license texts"
untouched
lock nonotice.lock det.onnx det.LICENSE
app nonotice
t_assert_rc 1 mirror --model locks/nonotice.lock det.onnx
t_assert_contains "$(cat "${w}/log")" "has no det.NOTICE"
untouched

t_case "a file the lock does not name, an archive, a second request for one model and a lock outside the repository are refused"
app refusals
t_assert_rc 1 mirror --model locks/models.lock other.onnx
t_assert_contains "$(cat "${w}/log")" "other.onnx is not in locks/models.lock"
t_assert_rc 1 mirror --model locks/models.lock text.tar.xz
t_assert_contains "$(cat "${w}/log")" "text.tar.xz is an archive"
t_assert_rc 1 mirror --model locks/models.lock det.onnx --model locks/release.lock det.onnx
t_assert_contains "$(cat "${w}/log")" "a model is named twice"
cp "${w}/repo/locks/models.lock" "${w}/outside.lock"
t_assert_rc 1 mirror --model ../outside.lock det.onnx
t_assert_contains "$(cat "${w}/log")" "is outside"
untouched

t_case "an app directory the build never wrote is refused, and a missing --model is a usage error"
app_dir="${w}/apps/never-built"
t_assert_rc 1 mirror --model locks/models.lock det.onnx
t_assert_contains "$(cat "${w}/log")" "is not a directory: the app's build wrote nothing there"
t_assert_eq 0 "$([ -e "${app_dir}" ] && echo 1 || echo 0)" "no app directory is made up"
app usage
t_assert_rc 2 mirror

t_summary
