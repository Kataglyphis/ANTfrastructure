#!/usr/bin/env bash
# docs-build.sh - generic "build a Sphinx documentation tree" core.
#
# Project-agnostic: a wrapper sets the DOCS_BUILD_* variables, sources this file
# and calls docs_build_main. Variables are in
# docs/shared-script-libraries.md § docs-build.sh.
# NOT 02-toolchain/python/ci_build_docs.sh -- that one is for pure-Python repos.
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.
[ -n "${_DOCS_BUILD_SH_LOADED:-}" ] && return 0
_DOCS_BUILD_SH_LOADED=1

_DOCS_BUILD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DOCS_BUILD_CORE_DIR="${_DOCS_BUILD_LIB_DIR}/../01-core"

# ---------------------------------------------------------------------------
# Shared helpers: prefer the real 01-core modules, fall back to local minimals
# ---------------------------------------------------------------------------
if ! declare -F info >/dev/null 2>&1; then
  if [[ -f "${_DOCS_BUILD_CORE_DIR}/logging.sh" ]]; then
    # shellcheck source=../01-core/logging.sh
    source "${_DOCS_BUILD_CORE_DIR}/logging.sh"
  fi
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fi
if ! declare -F err >/dev/null 2>&1; then
  err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
fi

_docs_build_root() {
  printf '%s\n' "${DOCS_BUILD_PROJECT_ROOT:-$(pwd)}"
}

_docs_build_docs_dir() {
  printf '%s\n' "${DOCS_BUILD_DOCS_DIR:-$(_docs_build_root)/docs}"
}

_docs_build_source_dir() {
  printf '%s\n' "${DOCS_BUILD_SOURCE_DIR:-$(_docs_build_docs_dir)/source}"
}

_docs_build_static_dir() {
  printf '%s\n' "${DOCS_BUILD_STATIC_DIR:-$(_docs_build_source_dir)/_static}"
}

# ---------------------------------------------------------------------------
# Python environment
# ---------------------------------------------------------------------------
# Venv creation and requirements install are delegated to the caller-supplied
# scripts (which in turn defer to 01-core/python_uv.sh) instead of a hand-rolled
# uv variant; they operate on the caller's cwd, hence the subshell cd. The
# activation itself must NOT be subshelled - Sphinx is run from this shell.
docs_build_prepare_python_env() {
  local root venv_dir create_script install_script
  root="$(_docs_build_root)"
  venv_dir="${DOCS_BUILD_VENV_DIR:-${root}/.venv}"
  create_script="${DOCS_BUILD_UV_VENV_CREATE_SCRIPT:-}"
  install_script="${DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT:-}"

  if [[ -z "${create_script}" || -z "${install_script}" ]]; then
    err "No venv bootstrap scripts configured (set DOCS_BUILD_UV_VENV_CREATE_SCRIPT and DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT)."
  fi

  info "Ensuring Python virtual environment and dependencies"
  (cd "${root}" && "${create_script}")
  (cd "${root}" && "${install_script}")

  info "Activating virtual environment"
  if [[ ! -f "${venv_dir}/bin/activate" ]]; then
    err "No virtualenv to activate at ${venv_dir}."
  fi
  # shellcheck disable=SC1091
  source "${venv_dir}/bin/activate"
}

# ---------------------------------------------------------------------------
# Pre-Sphinx asset staging
# ---------------------------------------------------------------------------
# Diagrams a CMake/Doxygen build emitted elsewhere have to reach _static before
# Sphinx runs, or the pages reference images that are not in the output tree.
docs_build_copy_static_svg() {
  local svg_dir static_dir
  svg_dir="${DOCS_BUILD_SVG_SOURCE_DIR:-}"
  [[ -n "${svg_dir}" ]] || return 0

  static_dir="$(_docs_build_static_dir)"
  info "Copying SVG files to docs static directory"
  mkdir -p "${static_dir}"
  cp "${svg_dir}"/*.svg "${static_dir}"
}

# Optional diagram generator (graphviz, plantuml, ...). Run with the Sphinx
# source dir as cwd, because such scripts resolve their outputs relative to it.
docs_build_run_generator() {
  local generator
  generator="${DOCS_BUILD_GENERATOR_SCRIPT:-}"
  [[ -n "${generator}" ]] || return 0

  info "Generating diagrams with ${generator}"
  (cd "$(_docs_build_source_dir)" && "${DOCS_BUILD_PYTHON:-python}" "${generator}")
}

# ---------------------------------------------------------------------------
# Sphinx
# ---------------------------------------------------------------------------
# `make <target>` per configured target, all under the same SPHINXOPTS. Each
# runs in a subshell so the caller's cwd survives the build.
docs_build_sphinx() {
  local docs_dir sphinxopts target
  docs_dir="$(_docs_build_docs_dir)"
  sphinxopts="${DOCS_BUILD_SPHINXOPTS--W --keep-going}"

  local targets=("${DOCS_BUILD_TARGETS[@]:-}")
  if [[ -z "${targets[0]:-}" ]]; then
    targets=(html linkcheck)
  fi

  for target in "${targets[@]}"; do
    info "Running 'make ${target}' in ${docs_dir} (SPHINXOPTS=${sphinxopts})"
    (cd "${docs_dir}" && SPHINXOPTS="${sphinxopts}" make "${target}")
  done
}

# Full pipeline: python env, asset staging, diagram generation, Sphinx.
docs_build_main() {
  docs_build_prepare_python_env
  docs_build_copy_static_svg
  docs_build_run_generator
  docs_build_sphinx
  info "Documentation build completed successfully"
}
