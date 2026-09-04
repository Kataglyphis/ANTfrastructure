#!/usr/bin/env bash
# Tests for verify_gate_registry.py. The gate derives its root from its own path,
# so each case copies it (plus the two modules it imports) into a throwaway tree
# holding a mini preflight.sh, suites, mutations.json, hook and docs/, then runs
# the real script against it.
# docs/code-quality-tooling.md#gate-proof-registry-gate-registry
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE_DIR="${TESTS_DIR%/tests}"
REG="docs/code-quality-gates.md"
PY="${PREFLIGHT_PYTHON:-python3}"
FROZEN_IDS='mutation-id:helper.y
mutation-id:omega.mismatch
mutation-id:beta.over-ordinary
mutation-id:alpha.foreign
mutation-family:wheels'

# Twelve slugs, one per shape: alpha (test), beta (own mutation), gamma (mutation on
# an imported sibling, credited by its id prefix), omega (same import, another
# gate's prefixes only -- must stay UNPROVEN), delta (unproven), epsilon ([ -f ] fallback
# pair, script under docs/scripts), zeta (inline fn in preflight.sh), eta (inline fn in
# a sourced lib), theta (inline fn also stubbed in a lib nobody sources), iota (run
# whole-tree by a hook block that fires only on staged docs), kappa (a block that
# scopes the gate with --changed rather than the guard variable), script-tests (by
# construction); plus ordinary.sh, the counter-shape no run_check registers.
# _subjects <dir>: the gate under test, its imports, and one script, lib, allow
# file and suite per fixture shape.
_subjects() {
  local d="$1"
  cp "${GATE_DIR}/verify_gate_registry.py" "${GATE_DIR}/quality_allow.py" \
     "${GATE_DIR}/verify_code_size.py" "${d}/linux/scripts/"
  printf 'import sys\n' > "${d}/linux/scripts/verify_alpha.py"
  printf 'import sys\n' > "${d}/linux/scripts/verify_beta.py"
  printf 'from helper import x\n' > "${d}/linux/scripts/verify_gamma.py"
  printf 'from helper import x\n' > "${d}/linux/scripts/verify_omega.py"
  printf 'import sys\n' > "${d}/linux/scripts/verify_iota.py"
  printf 'import sys\n' > "${d}/linux/scripts/verify_kappa.py"
  printf 'def x():\n    pass\n' > "${d}/linux/scripts/helper.py"
  printf ':\n' > "${d}/linux/scripts/delta.sh"
  printf ':\n' > "${d}/linux/scripts/ordinary.sh"
  printf 'import sys\n' > "${d}/docs/scripts/epsilon.py"
  printf 'bash linux/scripts/tests/gate-helper.sh\n' > "${d}/linux/scripts/tests/run-tests.sh"
  printf ':\n' > "${d}/linux/scripts/tests/gate-helper.sh"
  printf 'check_eta() {\n  :\n}\n' > "${d}/linux/scripts/01-core/eta-lib.sh"
  printf 'check_theta() {\n  : theta.allow\n}\n' > "${d}/linux/scripts/01-core/theta-lib.sh"
  printf 'check_theta() {\n  : decoy.allow\n}\ncheck_zeta() {\n  : decoy.allow\n}\n' \
    > "${d}/linux/scripts/01-core/decoy-lib.sh"
  : > "${d}/linux/scripts/zeta.allow"
  : > "${d}/linux/scripts/01-core/theta.allow"
  : > "${d}/linux/scripts/01-core/decoy.allow"
  : > "${d}/docs/scripts/code-dupes.allow"
  printf 'x verify_alpha.py\n' > "${d}/linux/scripts/tests/test-alpha.sh"
  printf 'x verify_gamma.py\n' > "${d}/linux/scripts/tests/test-gamma.sh"
  printf 'x epsilon.py\n' > "${d}/linux/scripts/tests/test-epsilon.sh"
  printf 'x verify_iota.py\n' > "${d}/linux/scripts/tests/test-iota.sh"
  printf 'x verify_kappa.py\n' > "${d}/linux/scripts/tests/test-kappa.sh"
  printf 'x check_zeta\n' > "${d}/linux/scripts/tests/test-zeta.sh"
  printf 'x check_eta\n' > "${d}/linux/scripts/tests/test-eta.sh"
  printf 'x check_theta\n' > "${d}/linux/scripts/tests/test-theta.sh"
  printf 'x preflight.sh eta-lib.sh theta-lib.sh\n' > "${d}/linux/scripts/tests/test-inline-decoy.sh"
  printf 'x not-delta.sh\n' > "${d}/linux/scripts/tests/test-not-delta.sh"
  printf '# the harness is not a suite: delta.sh\n' > "${d}/linux/scripts/tests/test-harness.sh"
}

_fixture() {
  local allow="$1" d
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts/tests" "${d}/linux/scripts/01-core" \
           "${d}/linux/host-config/git-hooks" "${d}/docs/scripts"
  _subjects "${d}"
  cat > "${d}/docs/scripts/mutations.json" <<'EOF'
[{"id": "beta.x", "target": "linux/scripts/verify_beta.py", "find": "a", "replace": "b", "test": "t", "why": "w"},
 {"id": "gamma.y", "target": "linux/scripts/helper.py", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/test-gamma.sh", "why": "w"},
 {"id": "omega.mismatch", "target": "linux/scripts/verify_beta.py", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/test-omega.sh", "why": "w"},
 {"id": "helper.y", "target": "linux/scripts/helper.py", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/test-gamma.sh", "why": "w"},
 {"id": "beta.over-ordinary", "target": "linux/scripts/ordinary.sh", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/test-beta.sh", "why": "w"},
 {"id": "wheels.ordinary", "target": "linux/scripts/ordinary.sh", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/test-wheels.sh", "why": "w"},
 {"id": "script-tests.helper", "target": "linux/scripts/tests/gate-helper.sh", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/run-tests.sh", "why": "w"},
 {"id": "alpha.callsite", "target": "linux/scripts/preflight.sh", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/test-alpha.sh", "why": "w"},
 {"id": "alpha.foreign", "target": "linux/scripts/ordinary.sh", "find": "a", "replace": "b",
  "test": "bash linux/scripts/tests/test-alpha.sh", "why": "w"}]
EOF
  cat > "${d}/linux/host-config/git-hooks/pre-commit" <<'EOF'
_FAST_SLUGS="alpha,beta,\
zeta"
if [ -n "${_staged_sh}" ]; then
  python3 linux/scripts/verify_gamma.py --files ${_staged_sh}
fi
if [ -n "${_staged_md}" ]; then
  python3 linux/scripts/verify_iota.py
fi
if [ -n "${_staged_any}" ]; then
  python3 linux/scripts/verify_kappa.py --changed
fi
bash -c 'source linux/scripts/01-core/eta-lib.sh; check_eta'
shellcheck -S error not-delta.sh
EOF
  cat > "${d}/linux/scripts/preflight.sh" <<'EOF'
KNOWN_SLUGS=(alpha beta gamma omega delta \
             epsilon zeta eta theta iota kappa script-tests)
run_check() { :; }
# code-dupes.allow is mentioned here, OUTSIDE check_zeta, and must not be zeta's
check_zeta() {
  : zeta.allow
}
run_check alpha "alpha gate" ${PREFLIGHT_PYTHON} linux/scripts/verify_alpha.py
run_check beta "beta gate" ${PREFLIGHT_PYTHON} linux/scripts/verify_beta.py
run_check gamma "gamma gate" ${PREFLIGHT_PYTHON} linux/scripts/verify_gamma.py
run_check omega "omega gate" ${PREFLIGHT_PYTHON} linux/scripts/verify_omega.py
run_check delta "delta gate" env X=1 bash linux/scripts/delta.sh
if [ -f docs/scripts/epsilon.py ]; then
  run_check epsilon "epsilon gate" ${PREFLIGHT_PYTHON} docs/scripts/epsilon.py --check
else
  run_check epsilon "epsilon gate" bash -c 'echo "docs/scripts/epsilon.py MISSING (moved/renamed? update preflight.sh)" >&2; exit 1'
fi
run_check zeta "zeta gate" check_zeta
run_check eta "eta gate" bash -c '
  source linux/scripts/01-core/eta-lib.sh
  X="${X:-eta-check}" check_eta'
run_check theta "theta gate" bash -c 'source linux/scripts/01-core/theta-lib.sh; check_theta'
run_check iota "iota gate" ${PREFLIGHT_PYTHON} linux/scripts/verify_iota.py
run_check kappa "kappa gate" ${PREFLIGHT_PYTHON} linux/scripts/verify_kappa.py
run_check script-tests "unit tests" bash linux/scripts/tests/run-tests.sh
EOF
  printf '%s\n%s\n' "${allow}" "${FROZEN_IDS}" > "${d}/linux/scripts/gate-proofs.allow"
  printf '%s' "${d}"
}

_run() { t_out "${PY}" "$1/linux/scripts/verify_gate_registry.py" "${@:2}"; }
_rc()  { t_rc "${PY}" "$1/linux/scripts/verify_gate_registry.py" "${@:2}"; }
_row() { grep "^| $2 |" "$1/${REG}"; }
_count_in_row() { printf '%s' "$(_row "$1" "$2")" | grep -c "$3"; }

# _written <allow>: a fixture frozen with <allow>, its registry already generated.
_written() {
  local fix; fix="$(_fixture "$1")"
  _run "${fix}" --write >/dev/null
  printf '%s' "${fix}"
}

# _unfrozen <line>: a written fixture that has lost that gate-proofs.allow line.
_unfrozen() {
  local fix; fix="$(_written "$(printf 'delta\nomega')")"
  sed -i "/$1/d" "${fix}/linux/scripts/gate-proofs.allow"
  printf '%s' "${fix}"
}

# _stale_after <fix> <line> <needle>: the fixture's own freezes back plus one more
# line, which nothing in the tree matches -- so the gate must fail saying STALE.
_stale_after() {
  printf 'delta\nomega\n%s\n%s\n' "${FROZEN_IDS}" "$2" > "$1/linux/scripts/gate-proofs.allow"
  t_assert_eq "1" "$(_rc "$1")" "a freeze nothing carries any more is STALE"
  t_assert_contains "$(_run "$1")" "$3"
}

# A tree frozen with <allow>, registry written; the check must FAIL and name every needle.
_fails_saying() {
  local allow="$1" fix out needle; shift
  fix="$(_written "${allow}")"
  out="$(_run "${fix}")"
  t_assert_eq "1" "$(_rc "${fix}")" "printing is not enough; it must fail"
  for needle in "$@"; do t_assert_contains "${out}" "${needle}"; done
  rm -rf "${fix}"
}

t_case "--write generates the registry, and the check then passes"
fix="$(_fixture "$(printf 'delta\nomega')")"
t_assert_eq "0" "$(_rc "${fix}" --write)" "--write must succeed on a proven-or-frozen tree"
t_assert_eq "<!-- generated by linux/scripts/verify_gate_registry.py --write; do not edit -->" \
  "$(head -1 "${fix}/${REG}")" "first line is the generated marker"
t_assert_eq "0" "$(_rc "${fix}")" "check mode passes right after --write"
t_assert_contains "$(_run "${fix}")" "OK: every slug is proven or frozen" "and says so"
t_assert_contains "$(_run "${fix}")" "12 slugs; 10 proven; 2 unproven, 2 frozen" "the census line"
t_assert_contains "$(_run "${fix}")" "1 mutation id(s) in 1 descriptive famil(ies), 1 declared" \
  "id and family freezes are counted apart from the unproven-slug list they share a file with"

t_case "the generated page states the proof rules it applied"
t_assert_contains "$(cat "${fix}/${REG}")" "an inline gate" "readers must see why a suite counts"
t_assert_contains "$(cat "${fix}/${REG}")" "imported module" "and when an inherited mutation does not"
t_assert_contains "$(cat "${fix}/${REG}")" "descriptive family" \
  "the page must state the rule for prefixes that name no slug, not imply every id is a slug"

t_case "the [ -f ] fallback line is skipped: the real script is registered"
t_assert_contains "$(_row "${fix}" epsilon)" "| docs/scripts/epsilon.py |" "not bash -c echo"
t_assert_contains "$(_row "${fix}" epsilon)" "| test |" "and its suite counts"

t_case "an inline preflight function resolves to its defining file"
t_assert_contains "$(_row "${fix}" zeta)" "| linux/scripts/preflight.sh |" "defined in preflight itself"
t_assert_contains "$(_row "${fix}" eta)" "| linux/scripts/01-core/eta-lib.sh |" "defined in a sourced lib"
t_assert_contains "$(_row "${fix}" theta)" "| linux/scripts/01-core/theta-lib.sh |" \
  "the lib the command sources, not the same-named stub in decoy-lib.sh"
t_assert_contains "$(_row "${fix}" theta)" "| linux/scripts/01-core/theta.allow |" "so its allow file is theta's"

t_case "an inline gate is keyed by its function name, not its host file"
t_assert_contains "$(_row "${fix}" zeta)" "linux/scripts/tests/test-zeta.sh" "the suite naming check_zeta"
t_assert_contains "$(_row "${fix}" eta)" "linux/scripts/tests/test-eta.sh" "the suite naming check_eta"
t_assert_eq "0" "$(_count_in_row "${fix}" zeta 'test-inline-decoy.sh')" \
  "a suite that only says preflight.sh proves no inline gate"
t_assert_eq "0" "$(_count_in_row "${fix}" eta 'test-inline-decoy.sh')" \
  "nor does naming the lib file instead of the function"

t_case "an inline function's allow scan is confined to its body"
t_assert_contains "$(_row "${fix}" zeta)" "| linux/scripts/zeta.allow |" "the literal inside the body"
t_assert_eq "0" "$(_count_in_row "${fix}" zeta 'code-dupes.allow')" \
  "a literal outside the body must not count"

t_case "a mutation is credited to the gate its id prefix names, over a file that gate owns"
t_assert_contains "$(_row "${fix}" gamma)" "| gamma.y |" "from helper import -> helper.py beside it"
t_assert_contains "$(_row "${fix}" gamma)" "| test+mutation |"
t_assert_contains "$(_row "${fix}" omega)" "| — | — | — | CI | UNPROVEN (frozen) |" \
  "same import, same module, another gate's prefix -> no free proof"
t_assert_contains "$(_row "${fix}" beta)" "| beta.x | hook+CI | mutation |" "a mutation on the script itself"
t_assert_eq "0" "$(_count_in_row "${fix}" gamma 'helper.y')" \
  "an off-convention id is credited to nobody, not to the gate whose file it targets"

t_case "an id prefix alone does not credit a mutation over a file the gate does not own"
t_assert_eq "0" "$(_count_in_row "${fix}" omega 'omega.mismatch')" \
  "omega.mismatch targets beta's script; omega owns verify_omega.py and helper.py"
t_assert_eq "0" "$(_count_in_row "${fix}" beta 'omega.mismatch')" "nor does beta take it by target"

t_case "a .sh gate owns the helper it SHELLS OUT to, the way a .py gate owns its imports"
t_assert_contains "$(_row "${fix}" script-tests)" "| script-tests.helper |" \
  "a shell gate imports nothing, so its extractor or sub-gate would otherwise belong to no row at all"

t_case "a mutation may pin the CALL SITE, in a file the gate does not own"
# preflight.sh belongs to zeta (an inline gate lives in it), so by target alone
# alpha.callsite credits nobody -- and the four ids over the real preflight.sh and
# the real pre-commit hook sat frozen on exactly that.
t_assert_contains "$(_row "${fix}" alpha)" "| alpha.callsite |" \
  "the target names verify_alpha.py and the suite it must turn red is alpha's own"
t_assert_eq "0" "$(_count_in_row "${fix}" zeta 'alpha.callsite')" \
  "and the gate that does own preflight.sh must not take it by target"
t_assert_eq "0" "$(_count_in_row "${fix}" alpha 'alpha.foreign')" \
  "ordinary.sh never NAMES verify_alpha.py, so it is not a call site however right the suite is"
t_assert_eq "0" "$(_count_in_row "${fix}" beta 'beta.over-ordinary')" \
  "the rule needs BOTH halves: beta's prefix over a file it does not own, with a suite that is not beta's, is still off-convention"

t_case "the hook tier reflects blocks that run a gate outside _FAST_SLUGS"
t_assert_contains "$(_row "${fix}" gamma)" "| hook (scoped)+CI |" "the hook runs verify_gamma.py on staged files"
t_assert_contains "$(_row "${fix}" eta)" "| hook (scoped)+CI |" "an inline gate the hook calls by function name"
t_assert_contains "$(_row "${fix}" omega)" "| CI |" "a gate the hook never names"
t_assert_contains "$(_row "${fix}" theta)" "| CI |" "and one whose lib the hook never sources"

t_case "a block that never hands the gate its staged list reads whole-tree, not scoped"
t_assert_contains "$(_row "${fix}" iota)" "| hook (whole tree, when relevant)+CI |" \
  "the iota block only guards on \${_staged_md}; the gate itself runs over everything"
t_assert_eq "0" "$(_count_in_row "${fix}" iota 'hook (scoped)')" \
  "calling it scoped would tell the reader the commit only checked what it staged"
t_assert_contains "$(_row "${fix}" kappa)" "| hook (scoped)+CI |" \
  "--changed is the staged list under another name"

t_case "a suite naming a longer basename does not prove the gate"
t_assert_contains "$(_row "${fix}" delta)" "| — | — | CI | UNPROVEN (frozen) |" \
  "test-not-delta.sh says not-delta.sh, which is not delta.sh"

t_case "hook tier follows _FAST_SLUGS, backslash continuation included"
t_assert_contains "$(_row "${fix}" alpha)" "| hook+CI |" "alpha is named first in _FAST_SLUGS"
t_assert_contains "$(_row "${fix}" zeta)" "| hook+CI |" "zeta sits on the continued line"
t_assert_contains "$(_row "${fix}" delta)" "| CI | UNPROVEN (frozen) |"

t_case "a mutation id whose prefix names no slug fails loudly, and its freeze ratchets"
fix2="$(_written "$(printf 'delta\nomega')")"
t_assert_eq "0" "$(_rc "${fix2}")" "frozen by the fixture, so the tree is clean"
t_assert_contains "$(_run "${fix2}")" "4 mutation id(s) off-convention, 4 frozen" "and counted separately"
sed -i '/mutation-id:helper.y/d' "${fix2}/linux/scripts/gate-proofs.allow"
t_assert_eq "1" "$(_rc "${fix2}")" "unfrozen, the convention breach must fail"
t_assert_contains "$(_run "${fix2}")" "prefix that cannot own it"
t_assert_contains "$(_run "${fix2}")" \
  "mutation-id:helper.y  (prefix names no preflight slug, and linux/scripts/helper.py is owned by gamma, omega)"
_stale_after "${fix2}" 'mutation-id:ghost.z' "STALE mutation-id freeze"
rm -rf "${fix2}"

t_case "a known prefix that does not own the target fails too, naming both"
fix2="$(_unfrozen 'mutation-id:omega.mismatch')"
t_assert_eq "1" "$(_rc "${fix2}")" "a typo in the prefix must not quietly stop proving anything"
t_assert_contains "$(_run "${fix2}")" \
  "mutation-id:omega.mismatch  (omega does not own linux/scripts/verify_beta.py -- owned by beta)"
rm -rf "${fix2}"

t_case "a slug prefix fails over a file no gate owns, not only over another gate's"
fix2="$(_unfrozen 'mutation-id:beta.over-ordinary')"
t_assert_eq "1" "$(_rc "${fix2}")" "ordinary.sh is nobody's gate; the claim in the prefix is still false"
t_assert_contains "$(_run "${fix2}")" \
  "mutation-id:beta.over-ordinary  (beta does not own linux/scripts/ordinary.sh -- owned by no gate)"
rm -rf "${fix2}"

t_case "a prefix that names no slug must be a declared descriptive family"
fix2="$(_unfrozen 'mutation-family:wheels')"
t_assert_eq "1" "$(_rc "${fix2}")" "an invented prefix over an ordinary script must not pass silently"
t_assert_contains "$(_run "${fix2}")" "neither a preflight slug nor a declared"
t_assert_contains "$(_run "${fix2}")" "mutation-family:wheels  (1 id(s))"
_stale_after "${fix2}" 'mutation-family:ghost' "STALE mutation-family declaration"
rm -rf "${fix2}"

t_case "script-tests is proven by construction"
t_assert_contains "$(_row "${fix}" script-tests)" "| by construction |"

t_case "a stale registry fails and says how to fix it"
printf '| ghost | ghost gate |\n' >> "${fix}/${REG}"
t_assert_eq "1" "$(_rc "${fix}")" "printing is not enough; it must fail"
t_assert_contains "$(_run "${fix}")" "is stale -- run: python3 linux/scripts/verify_gate_registry.py --write"
rm -f "${fix}/${REG}"
t_assert_eq "1" "$(_rc "${fix}")" "a missing registry is stale too"
rm -rf "${fix}"

t_case "an unproven slug that is not frozen fails as NEW, and the harness mention does not save it"
_fails_saying "" "NEW unproven slug(s)" "delta  (linux/scripts/delta.sh)" "omega  (linux/scripts/verify_omega.py)"

t_case "a frozen slug that is now proven fails as STALE -- the list only ratchets down"
_fails_saying "$(printf 'delta\nomega\nalpha')" "STALE entr(ies)" "  alpha"

t_case "a basename mention inside a comment counts as a suite"
fix="$(_fixture "omega")"
printf '# see delta.sh for the contract\n' > "${fix}/linux/scripts/tests/test-delta.sh"
_run "${fix}" --write >/dev/null
t_assert_eq "0" "$(_rc "${fix}")" "basename mention is the contract, comment or not"
rm -rf "${fix}"

t_case "KNOWN_SLUGS and run_check disagreeing is a loud error, not a partial table"
fix="$(_fixture "$(printf 'delta\nomega')")"
sed -i 's/ theta iota kappa script-tests)/ iota kappa script-tests)/' "${fix}/linux/scripts/preflight.sh"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" "KNOWN_SLUGS and run_check disagree: ['theta']"
rm -rf "${fix}"

t_case "the REAL tree is clean today"
t_assert_eq "0" "$( "${PY}" "${GATE_DIR}/verify_gate_registry.py" >/dev/null 2>&1; echo $? )"

t_summary
