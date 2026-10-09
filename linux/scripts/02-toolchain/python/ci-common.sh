#!/usr/bin/env bash
# Shared CI glue for the Python ci_*.sh drivers, sourced on top of 01-core/python_uv.sh.

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ../../, not ../: this file sits one level deeper than 02-toolchain/bootstrap.sh.
# shellcheck source=/dev/null
source "$_CI_COMMON_DIR/../../01-core/python_uv.sh"

# <initial>, else pyproject's name, else the workspace basename; needs WORKSPACE_ROOT set.
derive_package_name() {
  local name="${1:-}"
  if [ -z "$name" ] && [ -f "$WORKSPACE_ROOT/pyproject.toml" ]; then
    name=$(grep -m1 'name[[:space:]]*=' "$WORKSPACE_ROOT/pyproject.toml" | sed 's/.*=[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
  fi
  printf '%s' "${name:-$(basename "$WORKSPACE_ROOT")}"
}

# prepare_ci_workspace [--cd]: mutates WORKSPACE_ROOT (a bind-mounted /workspace wins).
prepare_ci_workspace() {
  if [ -d /workspace ] && [ -f /workspace/pyproject.toml ]; then
    WORKSPACE_ROOT="/workspace"
  fi
  if [ "${1:-}" = "--cd" ]; then
    cd "$WORKSPACE_ROOT" || die "Cannot cd into workspace: $WORKSPACE_ROOT"
  fi
  if [ -d "$WORKSPACE_ROOT/flutter/bin" ]; then
    export PATH="$WORKSPACE_ROOT/flutter/bin:$PATH"
  fi
  git config --global --add safe.directory "$WORKSPACE_ROOT" || true
}

# uv_venv_ensure <dir> <python> [label] [existed-outvar]: activates an existing venv, but not a new one.
uv_venv_ensure() {
  local dir="$1" pyver="$2" label="${3:-venv}" existed_outvar="${4:-}"
  local existed=0
  if [ -f "$dir/bin/activate" ]; then
    existed=1
    info "Using existing ${label} at $dir"
    uv_venv_activate "$dir"
  else
    info "Creating ${label} with Python $pyver at $dir"
    uv_venv_create "$dir" "$pyver"
  fi
  if [ -n "$existed_outvar" ]; then
    printf -v "$existed_outvar" '%s' "$existed"
  fi
}

# Copies the image's uv cache seed (PYTHON_UV_CACHE_SEED) into uv's cache. docs/consumer-image-contract.md#the-riscv64-uv-cache-seed
uv_cache_seed_restore() {
  local seed="${PYTHON_UV_CACHE_SEED:-}" record cache
  [ -n "${seed}" ] || return 0
  record="${seed}/seed-record.txt"
  if [ ! -f "${record}" ]; then
    warn "PYTHON_UV_CACHE_SEED=${seed} holds no seed-record.txt; nothing seeded"
    return 0
  fi
  if ! grep -qxF 'seeded yes' "${record}"; then
    info "uv cache seed: $(sed -n 's/^seeded no: //p' "${record}")"
    return 0
  fi
  if ! grep -qxF "arch $(uname -m)" "${record}"; then
    warn "uv cache seed ${seed} is $(sed -n 's/^arch //p' "${record}")'s, not $(uname -m)'s; not used"
    return 0
  fi
  cache="$(uv cache dir 2>/dev/null)" || { warn "uv cache dir failed; the seed is not used"; return 0; }
  mkdir -p "${cache}"
  # -R copies uv's relative archive symlinks as links; a seed entry may replace one of the same name.
  cp -R "${seed}/." "${cache}/" \
    || { warn "copying the uv cache seed into ${cache} failed; uv builds what it lacks"; return 0; }
  info "uv cache seeded from ${seed} into ${cache}: $(grep -c '^built ' "${record}") wheel(s) built from source for app $(sed -n 's/^app //p' "${record}")"
}
