#!/usr/bin/env bash
# The ORT Web loader in the image's Chrome under each condition of ort-web-loader-check.js, in the page and in a worker, against the stand-in ORT. See docs/docs-sites.md#loading-ort-web-in-an-app
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CHECK="${TESTS_DIR}/../ort-web-loader-check.js"
t_private_tmpdir
w="$(t_mktemp -d)"

t_skip_unless_chrome
site="$(t_mktemp -d)"
printf 'a fake session reads no model' > "${w}/model.onnx"
# case: what the loader must choose and answer there; the insecure page cannot check the files.
for spec in "jspi:jspi (jspi-webgpu)" "asyncify:asyncify (no-jspi)" "no-adapter:cpu (no-adapter)" "no-webgpu:cpu (no-webgpu)" \
  "insecure:cpu (no-secure-context), refused: unverifiable" "not-isolated:jspi (jspi-webgpu)"; do
  case_name="${spec%%:*}"
  for where in page worker; do
    t_case "in Chrome, ${case_name} in the ${where}"
    out="$(node "${CHECK}" --site "${site}" --case "${case_name}" --in "${where}" --fake-ort --model "${w}/model.onnx" --input-dims 1,2 \
      --out "${w}/${case_name}-${where}.json" 2>&1)"
    t_assert_eq 0 "$?" "${out}"
    t_assert_contains "${out}" "in the ${where}: ${spec#*:}"
  done
done
t_case "in Chrome, the not-isolated page runs one thread and the jspi session is proven on WebGPU"
out="$(node -e '
  const read = (f) => JSON.parse(require("fs").readFileSync(f, "utf8"));
  const [lone, jspi, cpu] = process.argv.slice(1).map(read);
  console.log(lone.provenance.threads, lone.provenance.threads_note, lone.provenance.capabilities.cross_origin_isolated,
    jspi.provenance.session.on_provider, jspi.provenance.session.proven, jspi.provenance.verified, cpu.provenance.session.placements.CPUExecutionProvider);
' "${w}/not-isolated-worker.json" "${w}/jspi-worker.json" "${w}/no-webgpu-page.json" 2>&1)"
t_assert_eq "1 not-isolated false 1 true true 1" "${out}"

t_case "in Chrome, an app's worker plans, loads and detects, the image sent beside the request"
mkdir -p "${site}/app"
cat > "${site}/app/worker.mjs" <<'JS'
onmessage = (event) => {
  const carried = typeof event.data === 'string' ? { request: event.data } : event.data;
  const m = JSON.parse(carried.request);
  const extra = m.op === 'detect' ? { bytes: carried.image.byteLength, threshold: m.threshold } : {};
  postMessage(JSON.stringify({ id: m.id, ok: true, provenance: { build: m.build, reason: 'requested', op: m.op }, ...extra }));
};
JS
printf 'twelve bytes' > "${w}/image.jpg"
out="$(node "${CHECK}" --site "${site}" --case no-adapter --worker app/worker.mjs --build cpu --image "${w}/image.jpg" --threshold 0.3 \
  --out "${w}/app.json" 2>&1)"
t_assert_eq 0 "$?" "${out}"
out="$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).steps;
  console.log(s.plan.provenance.op, s.load.provenance.op, s.detect.provenance.op, s.detect.provenance.build, s.detect.bytes, s.detect.threshold);
' "${w}/app.json" 2>&1)"
t_assert_eq "plan load detect cpu 12 0.3" "${out}"

t_summary
