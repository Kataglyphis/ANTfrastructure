#!/usr/bin/env bash
# stage-ort-web.py over fixture web outputs: build order, receipts, hashes, license texts and refusals. See docs/docs-sites.md#staging-ort-web-for-an-app
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
STAGE="${TESTS_DIR}/../lib/stage-ort-web.py"
PY="${PREFLIGHT_PYTHON:-python3}"

t_skip_unless "a POSIX python3" t_posix_python
t_private_tmpdir
w="$(t_mktemp -d)"

# fixture <dir> <wheel version>: a web output as the arm64 image has it, the amd64 bundles and a wheel beside it.
fixture() {
  "${PY}" -I - "$1" "$2" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

root, wheel = pathlib.Path(sys.argv[1]), sys.argv[2]
web, site = root / "web", root / "site" / "onnxruntime"
web.mkdir(parents=True); site.mkdir(parents=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
stem = "ort-wasm-simd-threaded"
for flavor in ("", ".jsep", ".asyncify", ".jspi"):
    (web / f"{stem}{flavor}.wasm").write_bytes(b"\0asm\x01\0\0\0" + flavor.encode())
    (web / f"{stem}{flavor}.mjs").write_text(f"loader{flavor}")
    (web / f"{stem}{flavor}.mjs.bak").write_text(f"old loader{flavor}")
for bundle in ("ort.jspi.min.mjs", "ort.jspi.mjs", "ort.webgpu.min.mjs", "ort.wasm.min.mjs", "ort.wasm.bundle.min.mjs",
               "ort.min.mjs", "ort.all.min.mjs", "ort.jspi.min.mjs.bak", "ort.jspi.min.mjs.map"):
    (web / bundle).write_text(bundle)
(web / "ort-webgpu-factory-probe.LICENSE").write_text("MIT probe")
source = {"ref": "v1.31.1", "revision": "6af1a932e2286d5c58166085d24c68783033edee"}
flavors = {}
for flavor in ("asyncify", "jspi"):
    product = {"path": f"{stem}.{flavor}.wasm", "sha256": sha(web / f"{stem}.{flavor}.wasm"),
               "loader": {"path": f"{stem}.{flavor}.mjs", "sha256": sha(web / f"{stem}.{flavor}.mjs")},
               "probe_license": {"path": "ort-webgpu-factory-probe.LICENSE", "sha256": sha(web / "ort-webgpu-factory-probe.LICENSE")}}
    runtime = web / f"ort-webgpu-wasm.{flavor}.runtime.json"
    runtime.write_text(json.dumps({"schema_version": 1, "flavor": flavor, "source": source, "product": product, "returncode": 0}))
    flavors[flavor] = {"configured_flags": {"onnxruntime_ENABLE_WEBASSEMBLY_JSPI": "ON" if flavor == "jspi" else "OFF"},
                       "cmake_cache_sha256": "c" * 64, "product": product,
                       "runtime": {"path": runtime.name, "sha256": sha(runtime)}}
(web / "ort-webgpu-wasm.json").write_text(json.dumps({"schema_version": 2, "source": source, "config": "Release", "flavors": flavors}))
(site / "LICENSE").write_text("MIT ORT")
(site / "ThirdPartyNotices.txt").write_text("third parties")
info = root / "site" / f"onnxruntime_webgpu-{wheel}.dist-info"
info.mkdir()
(info / "METADATA").write_text(f"Metadata-Version: 2.1\nName: onnxruntime-webgpu\nVersion: {wheel}\n")
record = lambda p: "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(p.read_bytes()).digest()).rstrip(b"=").decode()
(info / "RECORD").write_text("".join(f"onnxruntime/{n},{record(site / n)},{(site / n).stat().st_size}\n" for n in ("LICENSE", "ThirdPartyNotices.txt")))
PY
}
# case_tree <name> [wheel version]: a fresh fixture under ${w}/<name>.
case_tree() { rm -rf "${w:?}/$1"; fixture "${w}/$1" "${2:-1.31.1}"; t="${w}/$1"; }
stage() { "${PY}" -I "${STAGE}" --source "${t}/web" --out "${t}/out" --site-packages "${t}/site" "$@" > "${t}/log" 2>&1; }
log() { cat "${t}/log"; }
mf() { t_json "${t}/out/ort/manifest.json" "$1"; }
builds() { mf "' '.join(b['$1'] for b in m['builds'])"; }
# keys <section> <key>...: those values of one top-level manifest section.
keys() { mf "tuple(m['$1'][k] for k in '${*:2}'.split())"; }
# field <build index> <file field> [python condition on f]: that field of each matching file of one build.
field() { mf "' '.join(f['$2'] for f in m['builds'][$1]['files'] if ${3:-True})"; }
rehash() { "${PY}" -I - "${t}/web" <<'PY'
import hashlib
import json
import pathlib
import sys

web = pathlib.Path(sys.argv[1]); receipt = json.loads((web / "ort-webgpu-wasm.json").read_text())
for phase in receipt["flavors"].values():
    phase["product"]["sha256"] = hashlib.sha256((web / phase["product"]["path"]).read_bytes()).hexdigest()
    runtime = web / phase["runtime"]["path"]
    ran = json.loads(runtime.read_text()); ran["product"] = phase["product"]; runtime.write_text(json.dumps(ran))
    phase["runtime"]["sha256"] = hashlib.sha256(runtime.read_bytes()).hexdigest()
(web / "ort-webgpu-wasm.json").write_text(json.dumps(receipt))
PY
}

t_case "the default stages JSPI, Asyncify and CPU in that order, each under ort/<version>-<build hash>/"
case_tree ok
t_assert_ok stage
t_assert_eq "jspi asyncify cpu" "$(builds build)" "the app tries the builds in this order; JSEP only on request"
t_assert_eq 3 "$(find "${t}/out/ort" -mindepth 1 -maxdepth 1 -type d -name '1.31.1-????????????????' | wc -l | tr -d ' ')"
t_assert_eq "1.31.1 v1.31.1 6af1a932e2286d5c58166085d24c68783033edee Release" "$(keys ort version ref revision config)"
t_assert_eq "" "$(log | grep -v '^ORT-WEB-STAGE OK: ')" "a clean run prints one OK line per build"

t_case "each build holds its wasm, its loader, its own bundles and every license text, and nothing else"
jspi="$(mf "m['builds'][0]['path']")"
t_assert_eq $'LICENSE\nThirdPartyNotices.txt\nort-wasm-simd-threaded.jspi.mjs\nort-wasm-simd-threaded.jspi.wasm\nort-webgpu-factory-probe.LICENSE\nort.jspi.min.mjs\nort.jspi.mjs' \
  "$(ls "${t}/out/${jspi}" | LC_ALL=C sort)" "never a *.bak, a source map, or another build's bundle"
cpu="$(mf "m['builds'][2]['path']")"
t_assert_eq $'LICENSE\nThirdPartyNotices.txt\nort-wasm-simd-threaded.mjs\nort-wasm-simd-threaded.wasm\nort-webgpu-factory-probe.LICENSE\nort.wasm.bundle.min.mjs\nort.wasm.min.mjs' \
  "$(ls "${t}/out/${cpu}" | LC_ALL=C sort)"
t_assert_eq 0 "$(find "${t}/out" -name '*.bak' | wc -l | tr -d ' ')"
t_assert_eq "MIT ORT" "$(cat "${t}/out/${cpu}LICENSE")"

t_case "the manifest's hashes and sizes are the staged bytes, and the build hash is over them"
t_assert_eq "" "$("${PY}" -I - "${t}/out" <<'PY'
import hashlib
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1]); m = json.loads((out / "ort/manifest.json").read_text())
for b in m["builds"]:
    for f in b["files"]:
        p = out / b["path"] / f["file"]
        if hashlib.sha256(p.read_bytes()).hexdigest() != f["sha256"] or p.stat().st_size != f["size"]:
            print("differs:", p)
    listing = "".join(f"{f['sha256']}  {f['file']}\n" for f in b["files"])
    if b["path"] != f"ort/{m['ort']['version']}-{hashlib.sha256(listing.encode()).hexdigest()[:16]}/":
        print("path is not the build hash:", b["path"])
PY
)"

t_case "a build with a receipt records it; CPU, which has none, says so with receipt null"
t_assert_eq "jspi ON" "$(mf "m['builds'][0]['receipt']['flavor'], m['builds'][0]['receipt']['configured_flags']['onnxruntime_ENABLE_WEBASSEMBLY_JSPI']")"
t_assert_eq "ort-webgpu-wasm.asyncify.runtime.json" "$(mf "m['builds'][1]['receipt']['runtime']['path']")"
t_assert_eq None "$(mf "m['builds'][2]['receipt']")"
t_assert_eq "receipt receipt receipt" "$(field 0 hash_from "f['role'] in ('wasm', 'loader') or f['file'].startswith('ort-webgpu')")"
t_assert_eq "bytes bytes bytes bytes bytes bytes bytes" "$(field 2 hash_from)"
t_assert_eq "wheel onnxruntime-webgpu 1.31.1" "$(keys licenses from distribution version)"

t_case "--jsep adds the JSEP build last, with ort.min.mjs, the bundle that loads it"
case_tree jsep
t_assert_ok stage --jsep
t_assert_eq "jspi asyncify cpu jsep" "$(builds build)"
t_assert_eq "ort-wasm-simd-threaded.jsep.mjs ort-wasm-simd-threaded.jsep.wasm ort.min.mjs" \
  "$(field 3 file "f['role'] != 'license'")"

t_case "a missing requested build is refused, and nothing is staged"
for gone in ort-wasm-simd-threaded.jspi.wasm ort-wasm-simd-threaded.asyncify.mjs ort-wasm-simd-threaded.mjs; do
  case_tree "missing-${gone}"
  rm "${t}/web/${gone}"
  t_assert_fails stage
  t_assert_contains "$(log)" "${gone}"
  t_assert_eq 0 "$(find "${t}" -path '*/out/*' | wc -l | tr -d ' ')" "a refusal leaves no half tree behind"
done
case_tree missing-jsep
rm "${t}/web/ort-wasm-simd-threaded.jsep.wasm"
t_assert_fails stage --jsep
t_assert_ok stage

t_case "bytes that differ from the image's receipt are refused"
case_tree mismatch
printf 'x' >> "${t}/web/ort-wasm-simd-threaded.asyncify.wasm"
t_assert_fails stage
t_assert_contains "$(log)" "differs from the receipt"
case_tree mismatch-loader
printf 'x' >> "${t}/web/ort-wasm-simd-threaded.jspi.mjs"
t_assert_fails stage
case_tree mismatch-probe
printf 'x' >> "${t}/web/ort-webgpu-factory-probe.LICENSE"
t_assert_fails stage
case_tree mismatch-runtime
printf ' ' >> "${t}/web/ort-webgpu-wasm.jspi.runtime.json"
t_assert_fails stage

t_case "a WebGPU build the receipt does not prove is refused"
case_tree no-flavor
"${PY}" -I -c 'import json, sys; p = sys.argv[1]; r = json.load(open(p)); del r["flavors"]["jspi"]; json.dump(r, open(p, "w"))' "${t}/web/ort-webgpu-wasm.json"
t_assert_fails stage
t_assert_contains "$(log)" "no jspi flavor"
case_tree no-receipt
rm "${t}/web/ort-webgpu-wasm.json"
t_assert_fails stage
case_tree failed-probe
"${PY}" -I -c 'import json, sys; p = sys.argv[1]; r = json.load(open(p)); r["returncode"] = 1; json.dump(r, open(p, "w"))' "${t}/web/ort-webgpu-wasm.asyncify.runtime.json"
"${PY}" -I -c 'import hashlib, json, sys; p, q = sys.argv[1:]; r = json.load(open(p)); r["flavors"]["asyncify"]["runtime"]["sha256"] = hashlib.sha256(open(q, "rb").read()).hexdigest(); json.dump(r, open(p, "w"))' \
  "${t}/web/ort-webgpu-wasm.json" "${t}/web/ort-webgpu-wasm.asyncify.runtime.json"
t_assert_fails stage
t_assert_contains "$(log)" "failed probe"

t_case "the wheel's license texts are taken only when the wheel is the receipt's ORT version"
case_tree wheel-old 1.30.0
t_assert_fails stage
t_assert_contains "$(log)" "the onnxruntime wheel is 1.30.0, the receipt's ORT is 1.31.1"
case_tree wheel-record
printf 'changed' > "${t}/site/onnxruntime/ThirdPartyNotices.txt"
t_assert_fails stage
t_assert_contains "$(log)" "differs from its wheel's RECORD"
case_tree wheel-none
rm -r "${t}/site/onnxruntime_webgpu-1.31.1.dist-info"
t_assert_fails stage

t_case "license texts beside the web output come first, and need no wheel"
case_tree beside
printf 'MIT from the image' > "${t}/web/LICENSE"
printf 'notices from the image' > "${t}/web/ThirdPartyNotices.txt"
rm -r "${t}/site"
t_assert_ok stage
t_assert_eq "image" "$(mf "m['licenses']['from']")"
t_assert_eq "MIT from the image" "$(cat "${t}/out/$(mf "m['builds'][1]['path']")LICENSE")"
case_tree no-probe
rm "${t}/web/ort-webgpu-factory-probe.LICENSE"
t_assert_fails stage

t_case "a build without its JS bundle is refused unless --no-js-bundles says so, and the manifest records it"
case_tree no-bundles
rm "${t}/web/"ort.wasm*.mjs
t_assert_fails stage
t_assert_contains "$(log)" "no ort.wasm*.mjs bundle"
t_assert_ok stage --no-js-bundles
t_assert_eq "False" "$(mf "m['js_bundles']")"
t_assert_eq "" "$(mf "' '.join(f['file'] for b in m['builds'] for f in b['files'] if f['role'] == 'bundle')")"

t_case "new bytes in one build get that build a new path; the others keep theirs"
case_tree rehash
t_assert_ok stage
before="$(builds path)"
printf 'y' >> "${t}/web/ort-wasm-simd-threaded.wasm"
rm -rf "${t}/out"
t_assert_ok stage
after="$(builds path)"
t_assert_eq "${before% *}" "${after% *}"
t_assert_eq 1 "$([ "${before##* }" != "${after##* }" ] && echo 1 || echo 0)" "an old .wasm cached as immutable must never meet a new loader"
printf 'z' >> "${t}/web/ort-wasm-simd-threaded.jspi.wasm"
rehash
rm -rf "${t}/out"
t_assert_ok stage
t_assert_eq 1 "$([ "$(mf "m['builds'][0]['path']")" != "${after%% *}" ] && echo 1 || echo 0)"

t_case "an existing ort/ is refused rather than mixed with a new staging"
t_assert_fails stage
t_assert_contains "$(log)" "exists; remove it before staging"
t_assert_eq 0 "$(find "${t}/out" -maxdepth 1 -name '.ort-stage-*' | wc -l | tr -d ' ')"

t_summary
