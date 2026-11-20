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
deep = workspace / "packaging" / "licenses" / "cargo" / "vendor-1234"; deep.mkdir(parents=True); (deep / "LICENSE-MIT").write_bytes(b"vendored license\n")
nested = json.loads(json.dumps(policy)); nested["packages"]["app@1.0.0"]["files"].append({"root": "workspace", "path": "packaging/licenses/cargo/vendor-1234/LICENSE-MIT", "sha256": sha(deep / "LICENSE-MIT"), "provenance": "vendor commit 1234"}); save("nested-workspace.json", nested)
(workspace / "packaging" / "LICENSE").write_bytes(b"workspace license\n")
bad = json.loads(json.dumps(policy)); bad["packages"]["app@1.0.0"]["files"].append({"root": "workspace", "path": "packaging/LICENSE", "sha256": sha(workspace / "LICENSE"), "provenance": "same name"}); save("workspace-name-clash.json", bad)
notice = work / "registry" / "notice-only"; notice.mkdir(); (notice / "Cargo.toml").write_text("[package]\n"); (notice / "NOTICE").write_text("notice only\n")
bad = json.loads(json.dumps(metadata)); bad["packages"][1].update({"manifest_path": str(notice / "Cargo.toml"), "license_file": None, "license": "MIT"}); save("notice-only.json", bad)
graph = json.loads(json.dumps(metadata))
extra = {"macro": ("1.0.0", "proc-macro"), "helper": ("1.0.0", "lib"), "gfx-core": ("0.3.0", "lib"), "cc": ("1.0.0", "lib")}
for crate_name in extra:
    crate_root = work / "registry" / crate_name
    crate_root.mkdir()
    (crate_root / "Cargo.toml").write_text("[package]\n")
    (crate_root / "LICENSE").write_text(f"{crate_name} license\n")
    graph["packages"].append({"id": f"{crate_name}-id", "name": crate_name, "version": extra[crate_name][0], "manifest_path": str(crate_root / "Cargo.toml"), "license": "MIT", "license_file": None, "source": "registry+https://example.test/index", "targets": [{"kind": [extra[crate_name][1]]}]})
    graph["resolve"]["nodes"].append({"id": f"{crate_name}-id", "deps": []})
nodes = {node["id"]: node for node in graph["resolve"]["nodes"]}
edges = [("crate-id", "macro-id", None), ("macro-id", "helper-id", None), ("crate-id", "gfx-core-id", None), ("app-id", "cc-id", "build")]
for edge in edges:
    nodes[edge[0]]["deps"].append({"pkg": edge[1], "dep_kinds": [{"kind": edge[2], "target": None}]})
save("graph.json", graph)
(work / "graph-tree.txt").write_text("app v1.0.0 (/workspace/app)\ncrate v1.2.0\nmacro v1.0.0\nhelper v1.0.0\ngfx-core v0.3.0\ncc v1.0.0\n")
(work / "graph-normal-tree.txt").write_text("app v1.0.0 (/workspace/app)\ncrate v1.2.0\nmacro v1.0.0\ngfx-core v0.3.0\n")
PY

run_collector() {
  python3 "$SCRIPT" --workspace "$work/workspace" --root-package app --target x86_64-pc-windows-msvc \
    --metadata "$work/${1}" --policy "$work/${2}" --output-dir "$work/${3}" "${@:4}"
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

t_case 'a nested workspace text is staged under its name alone, keeping Windows install paths short'
t_assert_rc 0 run_collector metadata.json nested-workspace.json nested
t_assert_ok cmp "$work/workspace/packaging/licenses/cargo/vendor-1234/LICENSE-MIT" "$work/nested/app@1.0.0/workspace/LICENSE-MIT"
t_assert_fails test -e "$work/nested/app@1.0.0/workspace/packaging"

t_case 'missing, altered and unproven sources fail before publishing any output'
for policy in wrong-sha.json no-and-policy.json unreviewed-and.json no-workspace-policy.json traversal.json windows-traversal.json windows-drive.json windows-unc.json no-provenance.json duplicate.json workspace-name-clash.json; do
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
if [[ "${1:-}" = tree && " $* " = *" normal,build "* ]]; then cat "$CARGO_FIXTURE_TREE"; exit 0; fi
if [[ "${1:-}" = tree ]]; then cat "$CARGO_FIXTURE_NORMAL_TREE"; exit 0; fi
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

graph_run() { run_collector graph.json policy.json "$@" 2>&1; }

t_case 'without the graph options every selected package stages, proc macros included, and no budget line prints'
out="$(graph_run graph-default)"; rc=$?
t_assert_eq 0 "$rc"
t_assert_contains "$out" 'license files for 5 Cargo packages'
t_assert_eq 0 "$(grep -c -e 'runtime' <<<"$out")"

t_case 'a forbidden name anywhere in the staged graph fails before staging and prints its dependency path'
out="$(graph_run forbid-out --forbid-package 'gfx*' --forbid-package helper)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'forbidden Cargo package gfx-core@0.3.0 (gfx*): app@1.0.0 -> crate@1.2.0 -> gfx-core@0.3.0'
t_assert_contains "$out" 'forbidden Cargo package helper@1.0.0 (helper): app@1.0.0 -> crate@1.2.0 -> macro@1.0.0 -> helper@1.0.0'
t_assert_fails test -e "$work/forbid-out"

t_case 'a dev or unselected build dependency, a partial name and another case are not forbidden matches'
t_assert_rc 0 graph_run forbid-none --forbid-package dev --forbid-package cc --forbid-package gfx --forbid-package Crate

t_case 'an empty or unsafe pattern, a budget below the root and a budget over fixture metadata fail before staging'
t_assert_rc 1 graph_run bad-empty --forbid-package ''
t_assert_rc 1 graph_run bad-space --forbid-package 'gfx core'
t_assert_contains "$(graph_run bad-zero --max-runtime-packages 0)" 'counts the root, so it needs at least 1'
t_assert_rc 2 graph_run bad-word --max-runtime-packages many
t_assert_contains "$(graph_run bad-fixture --max-runtime-packages 9)" 'counts the live Cargo tree, not --metadata'
t_assert_fails test -e "$work/bad-fixture"

printf '#!/usr/bin/env bash\nprintf "rustc 1.2.3 (fixture)\\nhost: x86_64-unknown-linux-gnu\\n"\n' > "$work/bin/rustc"
chmod +x "$work/bin/rustc"
live_run() {
  local out="$1"
  shift
  env PATH="$work/bin:$PATH" RUSTC="$work/bin/rustc" CARGO_FIXTURE_LOG="$work/cargo-args" CARGO_FIXTURE_METADATA="$work/graph.json" \
    CARGO_FIXTURE_TREE="$work/graph-tree.txt" CARGO_FIXTURE_NORMAL_TREE="$work/graph-normal-tree.txt" python3 "$SCRIPT" \
    --workspace "$work/workspace" --root-package app --target x86_64-pc-windows-msvc --policy "$work/policy.json" \
    --output-dir "$work/${out}" "$@" 2>&1
}

t_case 'the runtime budget counts the live normal-edge tree, not the staged metadata graph or build edges'
out="$(live_run budget-ok --max-runtime-packages 4)"; rc=$?
t_assert_eq 0 "$rc"
t_assert_contains "$out" 'license files for 5 Cargo packages'
t_assert_contains "$out" 'PASS: 4 runtime Cargo packages, within the budget of 4'
out="$(live_run budget-over --max-runtime-packages 3)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'FAIL: Cargo graph gate:'
t_assert_contains "$out" '4 runtime Cargo packages exceed the budget of 3'
t_assert_fails test -e "$work/budget-over"

t_case 'the live tree scope forbids a build dependency with its path and still budgets only normal edges'
out="$(live_run tree-ok --graph-scope tree-normal-build --max-runtime-packages 4)"; rc=$?
t_assert_eq 0 "$rc"
t_assert_contains "$out" 'license files for 6 Cargo packages'
t_assert_contains "$out" 'PASS: 4 runtime Cargo packages, within the budget of 4'
out="$(live_run tree-cc --graph-scope tree-normal-build --forbid-package cc)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'forbidden Cargo package cc@1.0.0 (cc): app@1.0.0 -> cc@1.0.0'
t_assert_fails test -e "$work/tree-cc"

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
