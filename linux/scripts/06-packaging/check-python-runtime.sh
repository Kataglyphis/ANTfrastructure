#!/usr/bin/env bash
# The shipped interpreters' runtime checks: venv bytecode and the bundle builder's relocated CPython.

# Sourced by smoke-runtime-image.sh; sets no shell options.
_PYRT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# uid 1001 cannot write __pycache__ into root-owned /opt/venv, so an uncompiled venv re-parses every start.
check_venv_bytecode() {
  local image_tag="$1"
  local target_arch="$2"
    echo "--- AP2: venv byte-compiled (.pyc present) ---"
    if _rt_run \
      bash -lc 'find /opt/venv/lib -name "*.pyc" -print -quit 2>/dev/null | grep -q .'; then
      echo "  OK: /opt/venv ships .pyc (AP2 intact)"
    else
      fail "AP2 REGRESSED: no .pyc anywhere under /opt/venv/lib — venv not byte-compiled (VENV_COMPILE gate broken?)"
    fi
    echo ""
}

# python-app-bundle.sh stages this interpreter; a moved copy must run there. docs/python-app-bundles.md#the-relocated-image-cpython
check_relocatable_python() {
  # shellcheck disable=SC2034  # _rt_run reads image_tag by dynamic scope
  local image_tag="$1"
  local target_arch="$2"
  local tool out
  echo "--- Functional: the image's CPython runs from a moved copy (RELOCATABLE-PY) ---"
  tool="$(cat "${_PYRT_HERE}/python-relocate.py" 2>/dev/null)" || tool=""
  if [ -z "${tool}" ]; then
    fail "RELOCATABLE-PY: ${_PYRT_HERE}/python-relocate.py is missing, so the bundle runtime goes unproved"
    echo ""
    return 0
  fi
  out="$(_rt_run -e "PY_RELOCATE=${tool}" bash -c 'd="$(mktemp -d)" && printf "%s" "${PY_RELOCATE}" > "${d}/relocate.py" &&
    /usr/local/bin/python3 -I "${d}/relocate.py" stage --python /usr/local/bin/python3 --dest "${d}/tree" &&
    /usr/local/bin/python3 -I "${d}/relocate.py" check --tree "${d}/tree" && echo RELOCATE_DONE' 2>&1)" || true
  printf '%s\n' "${out}" | sed 's/^/  /'
  # Pattern matches, not grep -q: under pipefail an early grep exit fails the printf feeding it.
  if [[ $'\n'"${out}"$'\n' == *$'\nRELOCATE_DONE\n'* && $'\n'"${out}" != *$'\nFAIL: '* ]]; then
    pass "RELOCATABLE-PY: a moved copy of /usr/local's CPython runs on ${target_arch}"
  else
    fail "RELOCATABLE-PY: the image's CPython does not stage or run once moved on ${target_arch}; python-app-bundle.sh would fail"
  fi
  echo ""
}
