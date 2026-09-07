#!/usr/bin/env bash
# Characterisation of docs/scripts/sync_versions.py --check, the version-snapshot
# gate. Its verdict is an OR over seven sub-checks plus a licence subprocess, so
# anything less than one fixture per sub-check would credit the slug for six it
# never touched. The fixture is a SYMLINK FARM, because collect_versions() reads
# five fixed repo files and a full copy is 8 GB.
# docs/code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
export REPO

_roots="$(mktemp -d)"
trap 'rm -rf "${_roots}"' EXIT

# _farm <repo-relative path>... -> root. A tree of symlinks to the real repo with
# the named paths materialised as real, writable copies. sync_versions.py is
# always one of them: it resolves REPO_ROOT from __file__, and .resolve() would
# follow a symlink straight back to the real tree.
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

_check() { python3 "$1/docs/scripts/sync_versions.py" --check; }

t_case "the farm reproduces a GREEN verdict — every red below is measured against this"
# collect_versions() read-fails hard on five fixed files, four of them
# windows/, so a hand-built minimal tree cannot even reach a verdict.
_ok="$(_farm)"
t_assert_eq "0" "$(t_rc _check "${_ok}")" "an un-perturbed farm must be green"
_ok_out="$(t_out _check "${_ok}")"
for _line in "Generated version snapshot is up to date." \
             "Inline marker tokens are well-formed and known." \
             "Inline version markers are up to date." \
             "Dependency table is up to date." \
             "Dockerfile ARG defaults match versions.env." \
             "Windows build-script -DefaultValue pins match versions.env." \
             "Doc version literals match versions.env pins."; do
  t_assert_contains "${_ok_out}" "${_line}" "a sub-check that prints nothing green cannot be reddened on purpose"
done

# _red <expected stderr line> <path to perturb> <sed expr> [more path/sed pairs]
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

t_case "1/7 check_snapshot — the generated block in README.md"
_red "Generated version snapshot is out of date in:" \
  README.md 's|^<!-- generated:version-snapshot:start -->$|&\nDRIFT|'

t_case "2/7 validate_inline_marker_tokens — a marker name nothing resolves"
_red "unknown inline marker name 'generated:cudda'" \
  README.md '1i <!-- generated:cudda -->9.9<!-- /generated:cudda -->'

t_case "3/7 check_inline_markers — a well-formed marker carrying a stale value"
_red "Inline version markers are stale in:" \
  README.md '1i <!-- generated:gcc -->0.0.0<!-- /generated:gcc -->'

t_case "4/7 check_deps_table — the generated dependency table"
_red "Dependency table is out of date" \
  docs/third-party-licenses.md 's|^<!-- generated:deps-table:start -->$|&\nDRIFT|'

t_case "5/7 check_dockerfile_args — an ARG default drifting from versions.env"
_red "Dockerfile ARG defaults are stale:" \
  linux/Dockerfile.base 's|^ARG CMAKE_VERSION=.*|ARG CMAKE_VERSION=0.0.0|'

t_case "6/7 check_script_defaults is KNOWN-GAP: its glob matches nothing"
# script_default_target_files() globs windows/scripts/build-*-from-source.ps1.
# Those scripts live one directory deeper, in windows/scripts/build/, and are
# named Build-*FromSource.ps1 since the Verb-Noun rename (19982134), so the
# glob returns an EMPTY list and the sub-check prints its green line having
# scanned zero files. It cannot be reddened by any fixture, which is why this
# case pins the emptiness instead of faking a pass. Widening the glob turns ~10
# PowerShell scripts into gate subjects and any fallout is Windows-lane work, so
# it is the owner's call, not this suite's. The day the glob is fixed this case
# goes red, which is the point of pinning it.
t_assert_eq "0" "$(find "${REPO}/windows/scripts" -maxdepth 1 -name 'build-*-from-source.ps1' | wc -l)" \
  "the glob's own directory"
t_assert_eq "10" "$(find "${REPO}/windows/scripts/build" -maxdepth 1 -name 'Build-*FromSource.ps1' | wc -l)" \
  "and where the scripts actually are"
t_assert_contains "${_ok_out}" "Windows build-script -DefaultValue pins match versions.env." \
  "a green line over an empty file list is the whole finding"

t_case "7/7 check_doc_literals — a /opt/gcc-<version> literal in prose"
_red "stale gcc literal /opt/gcc-0.0.0" \
  AGENTS.md '1i See /opt/gcc-0.0.0 for the toolchain.'

t_case "8/8 the licence subprocess is ORed in, not merely run"
# The generator is a separate program; its verdict decides the slug too.
_lic="$(_farm docs/scripts/generate-website-licenses.py)"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n' > "${_lic}/docs/scripts/generate-website-licenses.py"
# result |= lic.returncode, so the generator's OWN code reaches the exit status.
t_assert_eq "3" "$(t_rc _check "${_lic}")" "a red licence generator must redden the gate"

t_case "the perturbations are DISJOINT — each reddens its own sub-check only"
# The OR is why this matters: a fixture that reddens two sub-checks proves one
# of them and hides the other behind the same non-zero exit.
_one="$(_farm linux/Dockerfile.base)"
sed -i 's|^ARG GCC_VERSION=.*|ARG GCC_VERSION=0.0.0|' "${_one}/linux/Dockerfile.base"
_one_out="$(t_out _check "${_one}")"
t_assert_contains "${_one_out}" "Generated version snapshot is up to date." "the snapshot sub-check must stay green"
t_assert_contains "${_one_out}" "Doc version literals match versions.env pins." "and so must the doc-literal one"

t_summary
