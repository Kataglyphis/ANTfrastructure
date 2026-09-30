#!/usr/bin/env bash
# Sourced Sphinx core (no shell options); ci_build_docs.sh is for pure-Python repos. docs/shared-script-libraries.md#docs-buildsh--build-a-sphinx-documentation-tree
[ -n "${_DOCS_BUILD_SH_LOADED:-}" ] && return 0
_DOCS_BUILD_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

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

# Python environment: never subshell the activation, since Sphinx runs from this shell.
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

# Pre-Sphinx staging: diagrams built elsewhere must reach _static before Sphinx runs.
docs_build_copy_static_svg() {
  local svg_dir static_dir
  svg_dir="${DOCS_BUILD_SVG_SOURCE_DIR:-}"
  [[ -n "${svg_dir}" ]] || return 0

  static_dir="$(_docs_build_static_dir)"
  info "Copying SVG files to docs static directory"
  mkdir -p "${static_dir}"
  cp "${svg_dir}"/*.svg "${static_dir}"
}

# Runs from the Sphinx source dir: generators resolve their outputs relative to it.
docs_build_run_generator() {
  local generator
  generator="${DOCS_BUILD_GENERATOR_SCRIPT:-}"
  [[ -n "${generator}" ]] || return 0

  info "Generating diagrams with ${generator}"
  (cd "$(_docs_build_source_dir)" && "${DOCS_BUILD_PYTHON:-python}" "${generator}")
}

# Sphinx: each target runs in a subshell so the caller's cwd survives.
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
