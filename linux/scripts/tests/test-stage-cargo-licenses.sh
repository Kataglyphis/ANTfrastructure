#!/usr/bin/env bash
# Verifies offline staging and provenance, not actual binary linkage or legal completeness.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="${TESTS_DIR}/../06-packaging/stage-cargo-licenses.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$work" "${TESTS_DIR}/fixtures/cargo-license" <<'PY'
import hashlib
import json
import pathlib
import sys

work = pathlib.Path(sys.argv[1])
workspace = work / "workspace"
app = workspace / "app"
crate = work / "registry" / "crate"
dev = work / "registry" / "dev"
for directory in (app, crate / "licenses", dev):
    directory.mkdir(parents=True, exist_ok=True)
for path, text in ((workspace / "LICENSE", b"workspace license\n"), (crate / "LICENSE", b"crate license\n"), (crate / "licenses" / "OFL.txt", b"font license\n")):
    path.write_bytes(text)
for directory in (app, crate, dev):
    (directory / "Cargo.toml").write_text("[package]\n", encoding="utf-8")
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
fixture = pathlib.Path(sys.argv[2])
values = {"@WORKSPACE@": workspace.as_posix(), "@APP@": app.as_posix(), "@CRATE@": crate.as_posix(), "@DEV@": dev.as_posix(), "@APP_SHA@": sha(workspace / "LICENSE"), "@FONT_SHA@": sha(crate / "licenses" / "OFL.txt")}
def template(name):
    text = (fixture / name).read_text(encoding="utf-8")
    for key, value in values.items():
        text = text.replace(key, json.dumps(value, ensure_ascii=False)[1:-1])
    return json.loads(text)
metadata = template("metadata.json")
policy = template("policy.json")
def save(name, value):
    (work / name).write_text(json.dumps(value), encoding="utf-8")
save("metadata.json", metadata)
save("policy.json", policy)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"][0]["sha256"] = "0" * 64; save("wrong-sha.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"].pop("crate@1.2.0"); save("no-and-policy.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"].pop("reviewed_expression"); save("unreviewed-and.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"].pop("app@1.0.0"); save("no-workspace-policy.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"][0]["path"] = "../LICENSE"; save("traversal.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"][0]["path"] = "..\\LICENSE"; save("windows-traversal.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"][0]["path"] = "C:\\LICENSE"; save("windows-drive.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"][0]["path"] = "\\\\server\\share\\LICENSE"; save("windows-unc.json", bad)
try:
    (crate / "licenses" / "link.txt").symlink_to(workspace / "LICENSE")
except OSError:
    pass
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"][0]["path"] = "licenses/link.txt"; save("symlink.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"][0]["provenance"] = ""; save("no-provenance.json", bad)
bad = json.loads(json.dumps(policy)); bad["packages"]["crate@1.2.0"]["files"].append(bad["packages"]["crate@1.2.0"]["files"][0]); save("duplicate.json", bad)
bad = json.loads(json.dumps(metadata)); bad["resolve"]["nodes"][0]["deps"][0]["dep_kinds"] = []; save("no-kind.json", bad)
bad = json.loads(json.dumps(metadata)); bad["workspace_root"] = str(work); save("wrong-workspace.json", bad)
bad = json.loads(json.dumps(metadata)); bad["packages"][1]["license_file"] = str(workspace / "LICENSE"); save("outside-license.json", bad)
bad = json.loads(json.dumps(metadata)); bad["packages"][1]["manifest_path"] = str(crate / "missing.toml"); save("missing-manifest.json", bad)
notice = work / "registry" / "notice-only"; notice.mkdir(); (notice / "Cargo.toml").write_text("[package]\n"); (notice / "NOTICE").write_text("notice only\n")
bad = json.loads(json.dumps(metadata)); bad["packages"][1].update({"manifest_path": str(notice / "Cargo.toml"), "license_file": None, "license": "MIT"}); save("notice-only.json", bad)
PY

run_collector() {
  python3 "$SCRIPT" --workspace "$work/workspace" --root-package app --target x86_64-pc-windows-msvc \
    --metadata "$work/${1}" --policy "$work/${2}" --output-dir "$work/${3}"
}

t_case 'the selected normal graph stages original package, nested and workspace texts'
t_assert_rc 0 run_collector metadata.json policy.json good
t_assert_ok cmp "$work/workspace/LICENSE" "$work/good/app@1.0.0/workspace/LICENSE"
t_assert_ok cmp "$work/registry/crate/LICENSE" "$work/good/crate@1.2.0/package/LICENSE"
t_assert_ok cmp "$work/registry/crate/licenses/OFL.txt" "$work/good/crate@1.2.0/package/licenses/OFL.txt"
t_assert_ok python3 - "$work/good/manifest.json" <<'PY'
import json
import pathlib
import sys

m = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert {p["name"] for p in m["packages"]} == {"app", "crate"}
assert m["selection"]["toolchain"] == {"evidence": "fixture", "cargo_version": None, "rustc_host": None}
assert m["packages"][1]["source"] == "registry+https://example.test/index"
assert m["packages"][0]["files"][0]["provenance"] == "workspace commit abc"
assert len(m["packages"][1]["files"]) == 2
PY

t_case 'missing, altered and unproven sources fail before publishing any output'
for policy in wrong-sha.json no-and-policy.json unreviewed-and.json no-workspace-policy.json traversal.json windows-traversal.json windows-drive.json windows-unc.json no-provenance.json duplicate.json; do
  t_assert_fails run_collector metadata.json "$policy" "out-${policy}"
  t_assert_fails test -e "$work/out-${policy}"
done
t_assert_fails run_collector notice-only.json no-and-policy.json notice-only-out
t_assert_fails test -e "$work/notice-only-out"
if [[ -L "$work/registry/crate/licenses/link.txt" ]]; then
  t_assert_fails run_collector metadata.json symlink.json symlink-out
  t_assert_fails test -e "$work/symlink-out"
fi

t_case 'the production path asks Cargo for locked offline target-filtered metadata'
mkdir -p "$work/bin"
cat > "$work/bin/cargo" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" = --version ]]; then printf 'cargo 1.2.3 (fixture)\n'; exit 0; fi
printf '%s\n' "$@" > "$CARGO_FIXTURE_LOG"
if [[ "${CARGO_FIXTURE_RC:-0}" -ne 0 ]]; then exit "$CARGO_FIXTURE_RC"; fi
cat "$CARGO_FIXTURE_METADATA"
SH
chmod +x "$work/bin/cargo"
t_assert_ok env PATH="$work/bin:$PATH" CARGO_FIXTURE_LOG="$work/cargo-args" CARGO_FIXTURE_METADATA="$work/metadata.json" \
  python3 "$SCRIPT" --workspace "$work/workspace" --root-package app --target x86_64-pc-windows-msvc --policy "$work/policy.json" --output-dir "$work/cargo-output"
t_assert_eq $'metadata\n--locked\n--offline\n--filter-platform\nx86_64-pc-windows-msvc\n--format-version\n1' "$(cat "$work/cargo-args")"
t_assert_fails env PATH="$work/bin:$PATH" CARGO_FIXTURE_LOG="$work/cargo-args" CARGO_FIXTURE_METADATA="$work/metadata.json" CARGO_FIXTURE_RC=7 \
  python3 "$SCRIPT" --workspace "$work/workspace" --root-package app --target x86_64-pc-windows-msvc --policy "$work/policy.json" --output-dir "$work/cargo-failed"
t_assert_fails test -e "$work/cargo-failed"

t_case 'malformed and foreign Cargo graphs cannot pass'
for metadata in no-kind.json wrong-workspace.json outside-license.json missing-manifest.json; do
  t_assert_fails run_collector "$metadata" policy.json "out-${metadata}"
  t_assert_fails test -e "$work/out-${metadata}"
done

t_case 'the output must be fresh and license sources cannot become empty'
t_assert_fails run_collector metadata.json policy.json good
printf '' > "$work/registry/crate/LICENSE"
t_assert_fails run_collector metadata.json policy.json empty
t_assert_fails test -e "$work/empty"

t_case 'publication is atomic and never replaces an existing destination'
t_assert_ok python3 "$TESTS_DIR/test_stage_cargo_publish.py"

t_summary
