#!/usr/bin/env bash
# sync_versions.py --check ORs eight sub-checks, so each gets its own fixture; see docs/code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
export REPO

_roots="$(mktemp -d)"
trap 'rm -rf "${_roots}"' EXIT

# _farm <path>...: a symlink farm (a full copy is 8 GB) with the named paths, and sync_versions.py, as real copies.
_farm() {
  ROOTS="${_roots}" python3 - "$@" <<'PY'
import os, shutil, sys, tempfile
repo = os.environ["REPO"]
root = tempfile.mkdtemp(dir=os.environ["ROOTS"])

def mirror(rel):
    src, dst = os.path.join(repo, rel), os.path.join(root, rel)
    os.makedirs(dst, exist_ok=True)
    for entry in os.listdir(src):
        link = os.path.join(dst, entry)
        if not os.path.lexists(link):
            os.symlink(os.path.join(src, entry), link)

mirror("")
for rel in list(sys.argv[1:]) + ["docs/scripts/sync_versions.py"]:
    acc = ""
    for part in os.path.dirname(rel).split("/"):
        if not part:
            continue
        acc = os.path.join(acc, part) if acc else part
        here = os.path.join(root, acc)
        if os.path.islink(here):
            os.unlink(here)
            mirror(acc)
    target, source = os.path.join(root, rel), os.path.join(repo, rel)
    if os.path.lexists(target):
        os.unlink(target)
    if os.path.exists(source):
        shutil.copy2(source, target)
print(root)
PY
}

# The eighth sub-check reads a consumer checkout, built here from two files rather than a real sibling.
_PIN="$(sed -n 's/^RUFF_VERSION=//p' "${REPO}/linux/scripts/01-core/tool-pins.env")"

# _consumer <ruff version> [pyproject body] [pre-commit body] -> root
_consumer() {
  local d ver="$1"
  d="$(mktemp -d -p "${_roots}")"
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" > "${d}/pyproject.toml"
  else
    printf 'dependencies = [\n    "ruff==%s",\n]\n' "${ver}" > "${d}/pyproject.toml"
  fi
  if [ "$#" -ge 3 ]; then
    printf '%s\n' "$3" > "${d}/.pre-commit-config.yaml"
  else
    printf 'repos:\n  - repo: https://github.com/astral-sh/ruff-pre-commit\n    rev: v%s\n    hooks:\n      - id: ruff\n' \
      "${ver}" > "${d}/.pre-commit-config.yaml"
  fi
  printf '%s\n' "${d}"
}

# An agreeing consumer rides along, so the eighth sub-check is really green rather than NOT CHECKED.
_OK_CONSUMER="$(_consumer "${_PIN}")"
_check() { python3 "$1/docs/scripts/sync_versions.py" --check --consumer-root "${_OK_CONSUMER}"; }
# _check_consumer <hub root> <consumer root>
_check_consumer() { python3 "$1/docs/scripts/sync_versions.py" --check --consumer-root "$2"; }
# _pins_only <hub root> [--consumer-root <dir>] — the mode run-lint-gates.sh calls
_pins_only() { local r="$1"; shift; python3 "${r}/docs/scripts/sync_versions.py" --consumer-pins "$@"; }

t_case "the farm reproduces a GREEN verdict — every red below is measured against this"
# collect_versions() fails hard without five fixed files, so a minimal tree cannot reach a verdict.
_ok="$(_farm)"
t_assert_eq "0" "$(t_rc _check "${_ok}")" "an un-perturbed farm must be green"
_ok_out="$(t_out _check "${_ok}")"
for _line in "Generated version snapshot is up to date." \
             "Inline marker tokens are well-formed and known." \
             "Inline version markers are up to date." \
             "Dependency table is up to date." \
             "Dockerfile ARG defaults match versions.env." \
             "Windows build-script -DefaultValue pins match versions.env." \
             "Doc version literals match versions.env pins." \
             "Consumer pins match versions.env:"; do
  t_assert_contains "${_ok_out}" "${_line}" "a sub-check that prints nothing green cannot be reddened on purpose"
done
t_assert_contains "${_ok_out}" "(2 compared)" \
  "both consumer rows must be compared -- a green line over one file is half a verdict"

# _red <stderr line> <path> <sed expr> [path expr]...; `\r\?` because *.md is CRLF on a Windows checkout.
_red() {
  local want="$1" root paths=() exprs=() i
  shift
  while [ "$#" -gt 0 ]; do paths+=("$1"); exprs+=("$2"); shift 2; done
  root="$(_farm "${paths[@]}")"
  for i in "${!paths[@]}"; do
    sed -i -e "${exprs[i]}" "${root}/${paths[i]}"
  done
  t_assert_eq "1" "$(t_rc _check "${root}")" "perturbing ${paths[0]} must fail the gate"
  t_assert_contains "$(t_out _check "${root}")" "${want}" "wrong sub-check reddened by ${paths[0]}"
}

t_case "1/8 check_snapshot — the generated block in README.md"
_red "Generated version snapshot is out of date in:" \
  README.md 's|^<!-- generated:version-snapshot:start -->\r\?$|&\nDRIFT|'

t_case "2/8 validate_inline_marker_tokens — a marker name nothing resolves"
_red "unknown inline marker name 'generated:cudda'" \
  README.md '1i <!-- generated:cudda -->9.9<!-- /generated:cudda -->'

t_case "3/8 check_inline_markers — a well-formed marker carrying a stale value"
_red "Inline version markers are stale in:" \
  README.md '1i <!-- generated:gcc -->0.0.0<!-- /generated:gcc -->'

t_case "4/8 check_deps_table — the generated dependency table"
_red "Dependency table is out of date" \
  docs/third-party-licenses.md 's|^<!-- generated:deps-table:start -->\r\?$|&\nDRIFT|'

t_case "5/8 check_dockerfile_args — an ARG default drifting from versions.env"
_red "Dockerfile ARG defaults are stale:" \
  linux/Dockerfile.base 's|^ARG CMAKE_VERSION=.*|ARG CMAKE_VERSION=0.0.0|'

t_case "6/8 check_script_defaults — a -DefaultValue drifting from versions.env"
# A glob that matches nothing makes this sub-check unreddenable, so its subject count is pinned.
t_assert_eq "16" "$(find "${REPO}/windows/scripts" -name 'Build-*FromSource.ps1' | wc -l)" \
  "the sixteen gate subjects the fixed glob must find (Build-LlamaCppHipFromSource.ps1 joined 2026-10-07)"
_red "Windows build-script -DefaultValue pins are stale:" \
  windows/scripts/build/Build-TvmFromSource.ps1 "s|-DefaultValue 'v0.27.0'|-DefaultValue 'v0.0.0'|"
t_assert_contains "$(cat "${REPO}/windows/scripts/build/Build-TvmFromSource.ps1")" \
  "-DefaultValue 'v0.27.0'" \
  "the commit override must leave the TAG fallback alone, not rewrite it to the hash"

t_case "7/8 check_doc_literals — a /opt/gcc-<version> literal in prose"
_red "stale gcc literal /opt/gcc-0.0.0" \
  AGENTS.md '1i See /opt/gcc-0.0.0 for the toolchain.'

t_case "8/8 check_consumer_pins — a consumer whose ruff pin contradicts versions.env"
# Its subject lives outside REPO_ROOT, so _red cannot reach it.
_drift="$(_consumer 0.0.0)"
t_assert_eq "1" "$(t_rc _check_consumer "${_ok}" "${_drift}")" \
  "a drifted consumer pin must fail the gate"
_drift_out="$(t_out _check_consumer "${_ok}" "${_drift}")"
t_assert_contains "${_drift_out}" "the \`\"ruff==<version>\"\` dependency pin is 0.0.0" \
  "the pyproject row must name the value it read"
t_assert_contains "${_drift_out}" "the ruff-pre-commit \`rev:\` is 0.0.0" \
  "and so must the .pre-commit row -- one row passing would hide the other"
t_assert_contains "${_drift_out}" "Generated version snapshot is up to date." \
  "and nothing else may go red with it"

t_case "8/8 the consumer files are read where a tool would read them, not by luck"
# Real consumers carry commented-out old pins and quoted `rev:` values.
_hist="$(_consumer "${_PIN}" \
  "dependencies = [
    # was \"ruff==0.0.0\" before the bump
    \"ruff==${_PIN}\",
]" \
  "repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: \"v${_PIN}\"   # quoted, and with a trailing comment
    hooks:
      - id: ruff")"
t_assert_eq "0" "$(t_rc _pins_only "${_ok}" --consumer-root "${_hist}")" \
  "a commented-out old pin is not the pin, and a quoted rev: is still the rev"
t_assert_contains "$(t_out _pins_only "${_ok}" --consumer-root "${_hist}")" "(2 compared)" \
  "both rows still have to be COMPARED -- passing by skipping them proves nothing"

t_case "8/8 two disagreeing declarations in one file are refused, not silently ranked"
# The correct pin comes first, so a first-match-wins extractor would read green.
_two="$(_consumer "${_PIN}" \
  "dependencies = [
    \"ruff==${_PIN}\",
    \"ruff==0.0.0\",
]")"
t_assert_eq "1" "$(t_rc _pins_only "${_ok}" --consumer-root "${_two}")" \
  "which one a parser reads is not this gate's guess to make"
t_assert_contains "$(t_out _pins_only "${_ok}" --consumer-root "${_two}")" \
  "declared more than once, with disagreeing values" "and it must say why"

t_case "8/8 --consumer-pins is the run-lint-gates.sh entry point, and refuses an empty run"
# The root is mandatory for this mode, so a missing one is a broken caller, not NOT CHECKED.
t_assert_eq "1" "$(t_rc _pins_only "${_ok}")" \
  "--consumer-pins with no root must FAIL, not report NOT CHECKED"
t_assert_contains "$(t_out _pins_only "${_ok}")" "Refusing to report a verdict over nothing." \
  "and say so"
t_assert_eq "0" "$(t_rc _pins_only "${_ok}" --consumer-root "${_OK_CONSUMER}")" \
  "a matching consumer passes"
t_assert_eq "1" "$(t_rc _pins_only "${_ok}" --consumer-root "${_drift}")" \
  "a drifted one fails"
t_assert_eq "1" "$(t_rc _pins_only "${_ok}" --consumer-root "${_roots}/no-such-consumer")" \
  "a named root that does not exist is an error, never a skip"
# The gate is WIRED: run-lint-gates.sh names this mode and lists the gate.
t_assert_ok grep -q -e '--consumer-pins' "${REPO}/linux/scripts/run-lint-gates.sh"
t_assert_ok grep -q -e 'run_gate "consumer pins" _lint_gates_consumer_pins' \
  "${REPO}/linux/scripts/run-lint-gates.sh"

t_case "8/8 a consumer that declares NEITHER file is an answer, not a green line over nothing"
_none="$(mktemp -d -p "${_roots}")"
t_assert_eq "0" "$(t_rc _pins_only "${_ok}" --consumer-root "${_none}")" \
  "a repo with no python packaging is not a failure"
t_assert_contains "$(t_out _pins_only "${_ok}" --consumer-root "${_none}")" "0 pins compared" \
  "but it must never read as 'checked and passed'"

# versions.env spells these as tags (v2.14.0); a consumer pins the bare number.
_env() { sed -n "s/^$1=v\{0,1\}//p" "${REPO}/linux/scripts/01-core/versions.env"; }
_TORCH="$(_env PYTORCH_VERSION)"
_VISION="$(_env TORCHVISION_VERSION)"
_GENAI="$(_env ONNXRUNTIME_GENAI_VERSION)"
# _ml <torch> <torchvision> <genai> -> a consumer shaped like OrchestrANT's extras
_ml() {
  _consumer "${_PIN}" "dependencies = [
    \"ruff==${_PIN}\",
    \"onnxruntime-genai==$3; platform_machine != 'riscv64'\",
    \"onnxruntime-genai-cuda==$3; sys_platform != 'darwin'\",
    \"onnxruntime-genai-directml; sys_platform == 'win32'\",
]
pytorch-cpu = [
    \"torch==$1; platform_machine != 'riscv64'\",
    \"torchvision==$2; platform_machine != 'riscv64'\",
    \"torch @ git+https://github.com/pytorch/pytorch.git@v$1 ; platform_machine == 'riscv64'\",
    \"torchvision @ git+https://github.com/pytorch/vision.git@v$2 ; platform_machine == 'riscv64'\",
]"
}

t_case "8/8 torch, torchvision and onnxruntime-genai are held to versions.env too"
_ml_ok="$(_ml "${_TORCH}" "${_VISION}" "${_GENAI}")"
t_assert_eq "0" "$(t_rc _pins_only "${_ok}" --consumer-root "${_ml_ok}")" \
  "a bare 2.14.0 IS versions.env's v2.14.0 -- the tag prefix is spelling, not drift"
t_assert_contains "$(t_out _pins_only "${_ok}" --consumer-root "${_ml_ok}")" "(7 compared)" \
  "every row must be COMPARED; an unpinned -directml is not a mention, so it adds none"

t_case "8/8 a drifted torch fails, and torchvision is not read as torch"
_ml_torch="$(_ml 0.0.0 "${_VISION}" "${_GENAI}")"
t_assert_eq "1" "$(t_rc _pins_only "${_ok}" --consumer-root "${_ml_torch}")" \
  "a torch pin behind the image's must fail"
_ml_torch_out="$(t_out _pins_only "${_ok}" --consumer-root "${_ml_torch}")"
t_assert_contains "${_ml_torch_out}" "the \`\"torch==<version>\"\` pin is 0.0.0" \
  "the wheel pin names the value it read"
t_assert_contains "${_ml_torch_out}" "the riscv64 \`pytorch.git@<tag>\` source pin is 0.0.0" \
  "and so does the riscv64 source pin"
t_assert_contains "${_ml_torch_out}" "(2 of 7 checked pin(s) wrong)" \
  "torchvision and genai stay green beside it"
_ml_vision_out="$(t_out _pins_only "${_ok}" --consumer-root "$(_ml "${_TORCH}" 0.0.0 "${_GENAI}")")"
t_assert_contains "${_ml_vision_out}" "the \`\"torchvision==<version>\"\` pin is 0.0.0" \
  "a torchvision drift is named as torchvision"
t_assert_fails grep -q -e 'the `"torch==<version>"` pin is' <<<"${_ml_vision_out}"
t_assert_contains "$(t_out _pins_only "${_ok}" --consumer-root "$(_ml "${_TORCH}" "${_VISION}" 0.0.0)")" \
  "the \`\"onnxruntime-genai[-cuda]==<version>\"\` pin is 0.0.0" \
  "and the genai pin is graded against its own key"

t_case "--write repairs the drift, and repairs NOTHING on the second run"
# --write must rewrite only what changed, or it churns every file it scans.
_w="$(_farm linux/Dockerfile.base)"
sed -i -e 's|^ARG CMAKE_VERSION=.*|ARG CMAKE_VERSION=0.0.0|' "${_w}/linux/Dockerfile.base"
_w_out="$(python3 "${_w}/docs/scripts/sync_versions.py" --write 2>&1)"
t_assert_contains "${_w_out}" "Synced Dockerfile ARG defaults in:" "the stale ARG must be repaired"
t_assert_eq "0" "$(grep -c -e '^ARG CMAKE_VERSION=0.0.0' "${_w}/linux/Dockerfile.base" || true)" \
  "the value itself, not just the report"
_w_mtime="$(stat -c %.Y "${_w}/linux/Dockerfile.base")"
_w_again="$(python3 "${_w}/docs/scripts/sync_versions.py" --write 2>&1)"
t_assert_contains "${_w_again}" "Dockerfile ARG defaults already match versions.env." \
  "a second --write must find nothing to do"
t_assert_eq "${_w_mtime}" "$(stat -c %.Y "${_w}/linux/Dockerfile.base")" \
  "a file nothing changed in must not be rewritten -- nanosecond mtime, because two runs land in the same second"

t_case "9/9 the licence subprocess is ORed in, not merely run"
# The generator is a separate program; its verdict decides the slug too.
_lic="$(_farm docs/scripts/generate-website-licenses.py)"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n' > "${_lic}/docs/scripts/generate-website-licenses.py"
# result |= lic.returncode, so the generator's OWN code reaches the exit status.
t_assert_eq "3" "$(t_rc _check "${_lic}")" "a red licence generator must redden the gate"

t_case "the perturbations are DISJOINT — each reddens its own sub-check only"
# Under the OR, a fixture reddening two sub-checks hides one behind the other's exit code.
_one="$(_farm linux/Dockerfile.base)"
sed -i 's|^ARG GCC_VERSION=.*|ARG GCC_VERSION=0.0.0|' "${_one}/linux/Dockerfile.base"
_one_out="$(t_out _check "${_one}")"
t_assert_contains "${_one_out}" "Generated version snapshot is up to date." "the snapshot sub-check must stay green"
t_assert_contains "${_one_out}" "Doc version literals match versions.env pins." "and so must the doc-literal one"
t_assert_contains "${_one_out}" "Consumer pins match versions.env:" "and the consumer one, whose subject is a different tree entirely"

t_summary
