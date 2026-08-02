#!/usr/bin/env bash
# docs-build.sh - generic "build a Sphinx documentation tree" core.
#
# Every project in this family builds its docs the same way: get a Python
# virtualenv with the docs requirements, pull whatever the C++/Doxygen side
# generated into _static, optionally run a diagram generator, then `make html`
# and `make linkcheck` with warnings promoted to errors. None of that is
# project-specific - only the paths and the extra pre-steps are.
#
# This library is project-agnostic: nothing project-specific is hard-coded here.
# A thin wrapper script sets the DOCS_BUILD_* variables below (its project
# defaults), sources this file, and calls docs_build_main.
#
# Not to be confused with 02-toolchain/python/ci_build_docs.sh, which is the
# docs step for pure-Python repositories (uv_sync_project over a pyproject,
# pytest/coverage report staging, no linkcheck). This one is the sourceable
# library for projects whose docs sit next to a C++/Rust build.
#
# It deliberately does NOT set -e / -u / -o pipefail so that sourcing it cannot
# change the caller's shell options; wrappers are expected to run under
# `set -euo pipefail` themselves.
#
# Optional caller variables (all have safe defaults):
#   DOCS_BUILD_PROJECT_ROOT      project root (default: cwd)
#   DOCS_BUILD_DOCS_DIR          directory holding the Sphinx Makefile
#                                (default: <root>/docs)
#   DOCS_BUILD_SOURCE_DIR        Sphinx source dir (default: <docs>/source)
#   DOCS_BUILD_STATIC_DIR        static asset dir (default: <source>/_static)
#   DOCS_BUILD_VENV_DIR          virtualenv to activate (default: <root>/.venv)
#   DOCS_BUILD_UV_VENV_CREATE_SCRIPT          script that creates the venv
#   DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT script that installs its
#                                requirements; both are run with the project
#                                root as cwd (same contract as
#                                code-quality.sh's pair, and both defer to
#                                01-core/python_uv.sh)
#   DOCS_BUILD_SVG_SOURCE_DIR    directory whose *.svg are copied into the
#                                static dir before the build (empty: skip).
#                                A missing SVG is fatal on purpose: an empty
#                                diagram set means the generating build did not
#                                run, and shipping docs with holes in them is
#                                worse than failing here.
#   DOCS_BUILD_GENERATOR_SCRIPT  Python script run with the source dir as cwd
#                                before Sphinx (empty: skip)
#   DOCS_BUILD_PYTHON            interpreter for that script (default: python)
#   DOCS_BUILD_SPHINXOPTS        SPHINXOPTS for every target
#                                (default: -W --keep-going, i.e. warnings are
#                                errors but the build reports all of them)
#   DOCS_BUILD_TARGETS           array of make targets
#                                (default: html linkcheck)
#
# Everything the wrapper does not provide is discovered from the environment:
# logging comes from 01-core/logging.sh (or minimal fallbacks) and tool presence
# checks from the caller's has_tool/require_tools when it declares them.

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
