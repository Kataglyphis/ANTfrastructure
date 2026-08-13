#!/usr/bin/env bash
# Invocation-idiom lints (backlog 0711f, promoted 2026-08-10 Batch 0).
# Two latent-bug classes that shellcheck cannot see, each of which has already
# cost a real run:
#
# 1. `${SUDO:-} --flag ...` — the prefix idiom is only safe when the next
#    token is a real command; with SUDO empty a bare FLAG becomes the command
#    (exit 127). Bug 7e6d627 shipped exactly this (`${SUDO:-} --preserve-env`),
#    masked by sdk cache until a no-cache run. The fixed site guards on
#    `[ -n "${SUDO:-}" ]` (vulkan.sh) — this lint keeps the class out.
#
# 2. `uv venv` without an explicit `--python` — uv then seeds from ambient
#    discovery (UV_PYTHON env, PATH), which inside images can point at the very
#    venv being (re)created: bug e3ffb0a ran `uv venv --clear` seeded from the
#    interpreter that --clear deletes ("No interpreter found", exit 2). All
#    live call sites pass --python today; this keeps new ones honest.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="${TESTS_DIR}/.."

# Collapse backslash-continuations so multi-line invocations are one logical
# line, then lint. Excludes tests/ (this file quotes the patterns).
_lint_tree() {  # _lint_tree <extended-regex> -> prints "file: line" hits
  local pattern="$1" f
  while IFS= read -r f; do
    sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba}' "${f}" 2>/dev/null \
      | grep -nE "${pattern}" \
      | sed "s|^|${f#"${SCRIPTS_DIR}"/}: |" || true
  done < <(find "${SCRIPTS_DIR}" -name '*.sh' -not -path '*/tests/*' -type f)
}

t_case "no bare flag directly after the \${SUDO:-} prefix idiom"
_sudo_hits="$(_lint_tree '\$\{SUDO(:-[^}]*)?\}[[:space:]]+-')"
t_assert_eq "" "${_sudo_hits}" "bare flag after \${SUDO:-} (becomes the command when SUDO is empty, exit 127):${_sudo_hits:+ }${_sudo_hits}"

t_case "every 'uv venv' invocation passes an explicit --python"
_uv_hits="$(_lint_tree 'uv[[:space:]]+venv' | grep -v -- '--python' || true)"
t_assert_eq "" "${_uv_hits}" "uv venv without --python (ambient seeding — the e3ffb0a class):${_uv_hits:+ }${_uv_hits}"

# 3. `uv pip install --force-reinstall` without `--no-deps` — a full-deps
#    force-reinstall RE-RESOLVES the wheel's dependency tree to latest,
#    silently floating the venv off the lock. Caught live 2026-08-11 by
#    assert_pinned_versions: numpy 2.5.1->2.5.2 (flagged) and protobuf
#    6.33.6->7.35.1 (a MAJOR bump no gate covered) — 8 sites fixed at once
#    (fix #7). This keeps the class out; deliberate full-deps installs should
#    not use --force-reinstall on locked packages.
t_case "every 'uv pip install --force-reinstall' pairs with --no-deps"
_fr_hits="$(_lint_tree 'uv[[:space:]]+pip[[:space:]]+install[[:space:]][^#]*--force-reinstall' | grep -v -- '--no-deps' || true)"
t_assert_eq "" "${_fr_hits}" "force-reinstall without --no-deps (lock-float — the fix-#7 numpy/protobuf class):${_fr_hits:+ }${_fr_hits}"

t_summary
