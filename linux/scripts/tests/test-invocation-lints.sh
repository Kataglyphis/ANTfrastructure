#!/usr/bin/env bash
# Invocation-idiom lints (backlog 0711f, promoted 2026-08-10 Batch 0).
# Latent-bug classes that shellcheck cannot see, each of which has already cost
# a real run. See the t_case lines below for the class descriptions.
#
# ── 2026-08-23: this suite was INERT and reported "3 assertion(s) passed" ─────
# SCRIPTS_DIR was "${TESTS_DIR}/.." — an unresolved path, so every path `find`
# printed contained the literal segment `tests/..` and `-not -path '*/tests/*'`
# excluded ALL 241 of them. Zero files were scanned; all three lints matched the
# empty string and passed. Three assertions of nothing, green for two weeks.
#
# The fix is not just the cd+pwd on line ~40. A tree-scanning lint has no
# natural failure signal — "found nothing" is what success looks like — so this
# suite now carries POSITIVE CONTROLS: a fixture tree with known-bad and
# known-good files that each lint must respectively flag and ignore, plus a
# direct assertion that the real scan reaches the real tree. Any future change
# that stops the scan reaching files fails the controls instead of passing
# silently. Do not delete them to "simplify".
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# cd+pwd, NOT "${TESTS_DIR}/..": see the header. The `tests/` exclusion below
# matches on the printed path, so an unresolved `..` in the root silently
# excludes the entire tree.
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

# How far back a lint looks for a guard that makes an otherwise-banned line
# safe. 3 logical lines: enough for `if <guard>; then` + a comment, tight enough
# that an unrelated guard elsewhere in the function cannot mask a real hit.
_LINT_GUARD_LOOKBACK=3

# The files a lint scans. tests/ is excluded because the suites in it quote the
# banned patterns verbatim, as fixtures and as documentation.
_lint_files() {  # <root>
  find "$1" -name '*.sh' -not -path '*/tests/*' -type f | LC_ALL=C sort
}

# Normalised view of one file, in this order:
#   1. FULL-LINE comments blanked — kept as empty lines so line numbers stay
#      true. DELIBERATE, and the answer to "should the lints scan comments?":
#      no. These lints ban an idiom from EXECUTING; prose that merely spells it
#      out cannot run and costs nothing. On the real tree 5 of 7 raw hits were
#      comments explaining the very bugs these lints exist to prevent
#      (01-core/common.sh's run_priv rationale, python_uv.sh, vulkan.sh), i.e.
#      scanning comments is a pure false-positive generator that pressures
#      authors to delete the explanation. A TRAILING comment is NOT stripped —
#      a `#` inside a string or a URL makes that unsafe to do blind — so prose
#      after code can still trip a lint; put it on its own line.
#   2. THEN backslash-continuations joined, so a multi-line invocation is one
#      logical line. Comment-blanking runs first in the same sed script so a
#      comment that happens to end in `\` cannot swallow the code line under it
#      (bash does not continue comments; sed's `N` does).
_lint_normalize() {  # <file>
  sed -e 's/^[[:space:]]*#.*$//' -e ':a' -e '/\\$/{N;s/\\\n/ /;ba}' "$1" 2>/dev/null
}

# _lint_tree <regex> <root> [guard-regex] -> one "relpath:LINE:text" per hit.
# With <guard-regex>, a hit is suppressed when one of the _LINT_GUARD_LOOKBACK
# preceding normalised lines matches it. That is how an already-correct GUARDED
# call site stays green without needing an opt-out marker in the source — see
# the vulkan.sh case in the ${SUDO} lint below.
_lint_tree() {
  local pattern="$1" root="$2" guard="${3:-}"
  local f rel n i j lo _before _quotes
  local -a lines
  while IFS= read -r f; do
    rel="${f#"${root}"/}"
    lines=()
    mapfile -t lines < <(_lint_normalize "${f}")
    n="${#lines[@]}"
    for (( i = 0; i < n; i++ )); do
      [[ "${lines[i]}" =~ $pattern ]] || continue
      # A match inside a double-quoted string is a MESSAGE, not a call:
      # `info "Using existing uv venv (expected at ...)"` is not an invocation.
      # Odd number of `"` before the match => we are inside one. Cheap and
      # general (it covers `sudo uv venv`, `if uv venv`, env-assign prefixes and
      # every other command-position spelling without enumerating them). Known
      # blind spot: a genuine violation built inside `eval "..."` is skipped.
      _before="${lines[i]%%"${BASH_REMATCH[0]}"*}"
      _quotes="${_before//[^\"]/}"
      [ $(( ${#_quotes} % 2 )) -eq 1 ] && continue
      if [ -n "${guard}" ]; then
        lo=$(( i - _LINT_GUARD_LOOKBACK ))
        [ "${lo}" -lt 0 ] && lo=0
        for (( j = lo; j < i; j++ )); do
          [[ "${lines[j]}" =~ $guard ]] && continue 2
        done
      fi
      printf '%s:%d:%s\n' "${rel}" "$(( i + 1 ))" "${lines[i]}"
    done
  done < <(_lint_files "${root}")
}

# ─────────────────────────────────────────────────────────────────────────────
# LINT 1 — a bare flag directly after an inline ${SUDO} command prefix.
#
# The prefix idiom is only safe when the next token is a real command; with SUDO
# empty (already root — every foreign-arch cross container) a bare FLAG becomes
# the command and the shell exits 127. Bug 7e6d627 shipped exactly that, masked
# by the sdk cache until a no-cache run. 01-core/common.sh's run_priv is the
# replacement; 02-toolchain/vulkan.sh:346 is the fixed-in-place variant and is
# why this lint understands guards.
_SUDO_PATTERN='\$\{SUDO(:-[^}]*)?\}[[:space:]]+-'
_SUDO_GUARD='-n[[:space:]]+"?\$\{SUDO'

# LINT 2 — `uv venv` without an explicit `--python`.
#
# uv then seeds from ambient discovery (UV_PYTHON, PATH), which inside images
# can point at the very venv being (re)created: bug e3ffb0a ran `uv venv
# --clear` seeded from the interpreter that --clear deletes ("No interpreter
# found", exit 2).
_UV_PATTERN='uv[[:space:]]+venv'

# LINT 3 — `uv pip install --force-reinstall` without `--no-deps`.
#
# A full-deps force-reinstall RE-RESOLVES the wheel's dependency tree to latest,
# silently floating the venv off the lock. Caught live 2026-08-11 by
# assert_pinned_versions: numpy 2.5.1->2.5.2 and protobuf 6.33.6->7.35.1 (a
# MAJOR bump no gate covered) — 8 sites fixed at once (fix #7).
_FR_PATTERN='uv[[:space:]]+pip[[:space:]]+install[[:space:]][^#]*--force-reinstall'

# ${name[@]} indirection for LINT 2. `uv venv "${venv_args[@]}"` builds its argv
# in an array, so --python sits in the array literal a few lines up rather than
# on the invocation line (06-packaging/setup-torch-venv.sh:99 does exactly
# this). Resolve that ONE indirection. An array whose literal cannot be found
# stays a HIT — unresolvable is loud, never quietly exempt.
_uv_python_reachable() {  # <abs-file> <hit-text>
  local file="$1" rest="$2" name
  while [[ "${rest}" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\} ]]; do
    name="${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    if grep -E "(^|[^A-Za-z0-9_])${name}\+?=\(" "${file}" 2>/dev/null | grep -q -- '--python'; then
      return 0
    fi
  done
  return 1
}

_uv_violations() {  # <root>
  local root="$1" hit file text out=""
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    case "${hit}" in *--python*) continue ;; esac
    file="${root}/${hit%%:*}"
    text="${hit#*:}"; text="${text#*:}"
    _uv_python_reachable "${file}" "${text}" && continue
    out="${out}${out:+$'\n'}${hit}"
  done < <(_lint_tree "${_UV_PATTERN}" "${root}")
  printf '%s' "${out}"
}

_fr_violations() {  # <root>
  _lint_tree "${_FR_PATTERN}" "$1" | grep -v -- '--no-deps' || true
}

# ─────────────────────────────────────────────────────────────────────────────
# POSITIVE CONTROLS. Without these the lints have no way to fail loudly, which
# is precisely how they sat inert for two weeks. Each fixture is a file the lint
# MUST flag or MUST ignore; a scan that reaches nothing fails half of them.
_FIX="$(mktemp -d)"
trap 'rm -rf "${_FIX}"' EXIT
mkdir -p "${_FIX}/tests"

cat > "${_FIX}/sudo-bad.sh" <<'FIXTURE'
#!/usr/bin/env bash
SUDO=""
${SUDO:-} --preserve-env=PATH ./vulkansdk -j 4
FIXTURE

cat > "${_FIX}/sudo-guarded.sh" <<'FIXTURE'
#!/usr/bin/env bash
if [ -n "${SUDO:-}" ]; then
  ${SUDO} --preserve-env=PATH ./vulkansdk -j 4
else
  ./vulkansdk -j 4
fi
FIXTURE

cat > "${_FIX}/sudo-comment.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Prose only: ${SUDO:-} --preserve-env=X ./vulkansdk is the banned spelling.
echo ok
FIXTURE

cat > "${_FIX}/uv-bad.sh" <<'FIXTURE'
#!/usr/bin/env bash
uv venv --clear /opt/venv
FIXTURE

cat > "${_FIX}/uv-good.sh" <<'FIXTURE'
#!/usr/bin/env bash
uv venv --python=/usr/local/bin/python3.14 /opt/venv
FIXTURE

cat > "${_FIX}/uv-array-good.sh" <<'FIXTURE'
#!/usr/bin/env bash
venv_args=(--seed --python="${python_bin}")
uv venv "${venv_args[@]}" /opt/venv
FIXTURE

cat > "${_FIX}/uv-array-bad.sh" <<'FIXTURE'
#!/usr/bin/env bash
venv_args=(--seed --system-site-packages)
uv venv "${venv_args[@]}" /opt/venv
FIXTURE

cat > "${_FIX}/fr-bad-continued.sh" <<'FIXTURE'
#!/usr/bin/env bash
uv pip install \
  --force-reinstall \
  numpy
FIXTURE

cat > "${_FIX}/fr-good.sh" <<'FIXTURE'
#!/usr/bin/env bash
uv pip install --force-reinstall --no-deps numpy
FIXTURE

cat > "${_FIX}/tests/nested-bad.sh" <<'FIXTURE'
#!/usr/bin/env bash
${SUDO:-} --preserve-env=PATH ./vulkansdk
uv venv --clear /opt/venv
FIXTURE

_sudo_fixture_hits="$(_lint_tree "${_SUDO_PATTERN}" "${_FIX}" "${_SUDO_GUARD}")"
_uv_fixture_hits="$(_uv_violations "${_FIX}")"
_fr_fixture_hits="$(_fr_violations "${_FIX}")"

t_case "control: the \${SUDO} lint FIRES on an unguarded bare flag"
t_assert_contains "${_sudo_fixture_hits}" "sudo-bad.sh:3:" \
  "the lint must detect the 7e6d627 idiom — if this is empty the scan reached no files"

t_case "control: the \${SUDO} lint IGNORES a site guarded by [ -n \"\${SUDO:-}\" ]"
case "${_sudo_fixture_hits}" in
  *sudo-guarded.sh*) _g="flagged" ;; *) _g="clean" ;;
esac
t_assert_eq "clean" "${_g}" "02-toolchain/vulkan.sh:346 is this shape and is correct as written"

t_case "control: the \${SUDO} lint IGNORES the idiom inside a full-line comment"
case "${_sudo_fixture_hits}" in
  *sudo-comment.sh*) _c="flagged" ;; *) _c="clean" ;;
esac
t_assert_eq "clean" "${_c}" "the ban is on code; prose explaining the bug must stay writable"

t_case "control: the uv-venv lint FIRES without --python and stays quiet with it"
t_assert_contains "${_uv_fixture_hits}" "uv-bad.sh:2:" "the e3ffb0a idiom must be detected"
case "${_uv_fixture_hits}" in *uv-good.sh*) _u="flagged" ;; *) _u="clean" ;; esac
t_assert_eq "clean" "${_u}" "an explicit --python must not be flagged"

t_case "control: the uv-venv lint resolves ONE array indirection, both ways"
case "${_uv_fixture_hits}" in *uv-array-good.sh*) _ag="flagged" ;; *) _ag="clean" ;; esac
t_assert_eq "clean" "${_ag}" "--python inside the array literal counts (setup-torch-venv.sh:99)"
t_assert_contains "${_uv_fixture_hits}" "uv-array-bad.sh:3:" \
  "an array WITHOUT --python must still be a hit — the array form is not a blanket exemption"

t_case "control: the force-reinstall lint survives backslash-continuation"
t_assert_contains "${_fr_fixture_hits}" "fr-bad-continued.sh:2:" \
  "a multi-line invocation must be linted as one logical line"
case "${_fr_fixture_hits}" in *fr-good.sh*) _fg="flagged" ;; *) _fg="clean" ;; esac
t_assert_eq "clean" "${_fg}" "--no-deps must not be flagged"

t_case "control: tests/ is excluded (these suites quote the banned patterns)"
case "${_sudo_fixture_hits}${_uv_fixture_hits}" in
  *nested-bad.sh*) _n="scanned" ;; *) _n="excluded" ;;
esac
t_assert_eq "excluded" "${_n}"

t_case "control: the real scan actually reaches the real script tree"
_scanned="$(_lint_files "${SCRIPTS_DIR}" | wc -l)"
_enough="no"; [ "${_scanned}" -gt 100 ] && _enough="yes"
t_assert_eq "yes" "${_enough}" \
  "only ${_scanned} *.sh files scanned — the lints are inert (the SCRIPTS_DIR='tests/..' bug)"
t_assert_contains "$(_lint_files "${SCRIPTS_DIR}")" "/01-core/common.sh" \
  "a known file must be in the scan list, so the exclusion is not over-broad"

# ─────────────────────────────────────────────────────────────────────────────
# THE ACTUAL LINTS, against the real tree.
t_case "no bare flag directly after an inline \${SUDO} command prefix"
_sudo_hits="$(_lint_tree "${_SUDO_PATTERN}" "${SCRIPTS_DIR}" "${_SUDO_GUARD}")"
t_assert_eq "" "${_sudo_hits}" \
  "bare flag after an inline \${SUDO} prefix (becomes the command when SUDO is empty, exit 127); use run_priv or guard on [ -n \"\${SUDO:-}\" ]:${_sudo_hits:+ }${_sudo_hits}"

t_case "every 'uv venv' invocation passes an explicit --python"
_uv_hits="$(_uv_violations "${SCRIPTS_DIR}")"
t_assert_eq "" "${_uv_hits}" \
  "uv venv without --python (ambient seeding — the e3ffb0a class):${_uv_hits:+ }${_uv_hits}"

t_case "every 'uv pip install --force-reinstall' pairs with --no-deps"
_fr_hits="$(_fr_violations "${SCRIPTS_DIR}")"
t_assert_eq "" "${_fr_hits}" \
  "force-reinstall without --no-deps (lock-float — the fix-#7 numpy/protobuf class):${_fr_hits:+ }${_fr_hits}"

t_summary
