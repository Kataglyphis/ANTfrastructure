#!/usr/bin/env bash
# Sourced core (no shell options); dart doc's only seams are styles.css and its HTML. docs/shared-script-libraries.md#dartdoc-buildsh--theme-and-enrich-a-dart-doc-site
[ -n "${_DARTDOC_BUILD_SH_LOADED:-}" ] && return 0
_DARTDOC_BUILD_SH_LOADED=1

_DARTDOC_BUILD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log-bootstrap.sh
source "${_DARTDOC_BUILD_LIB_DIR}/log-bootstrap.sh"

_dartdoc_build_root() {
  printf '%s\n' "${DARTDOC_BUILD_PROJECT_ROOT:-$(pwd)}"
}

_dartdoc_build_doc_root() {
  printf '%s\n' "${DARTDOC_BUILD_DOC_ROOT:-$(_dartdoc_build_root)/doc}"
}

_dartdoc_build_api_dir() {
  printf '%s\n' "$(_dartdoc_build_doc_root)/api"
}

# A missing tree means the generator never ran; a later step would report green over nothing.
_dartdoc_build_require_api_dir() {
  local api_dir
  api_dir="$(_dartdoc_build_api_dir)"
  if [[ ! -d "${api_dir}" ]]; then
    err "No generated documentation at ${api_dir} (did dartdoc_build_generate run?)."
  fi
  printf '%s\n' "${api_dir}"
}

# Python environment: container-native, used by path so no set -u dance around activate.
dartdoc_build_prepare_python_env() {
  local venv_dir requirements python
  if [[ -n "${DARTDOC_BUILD_PYTHON:-}" ]]; then
    info "Using the caller's interpreter: ${DARTDOC_BUILD_PYTHON}"
    return 0
  fi
  venv_dir="${DARTDOC_BUILD_VENV_DIR:-${TMPDIR:-/tmp}/kataglyphis-dartdoc-venv}"
  requirements="${_DARTDOC_BUILD_LIB_DIR}/dartdoc-guides.requirements.txt"
  requirements="${DARTDOC_BUILD_REQUIREMENTS:-${requirements}}"

  # shellcheck source=../01-core/python_uv.sh
  source "${_DARTDOC_BUILD_LIB_DIR}/../01-core/python_uv.sh"
  uv_ensure_installed
  uv_venv_create "${venv_dir}" "" # "" skips the --python pin, honouring UV_PYTHON
  uv_pip_install_requirements "${venv_dir}" "${requirements}"

  python="${venv_dir}/bin/python"
  if [[ ! -x "${python}" ]]; then
    python="${venv_dir}/Scripts/python.exe"
  fi
  if [[ ! -x "${python}" ]]; then
    err "No usable interpreter in ${venv_dir} after uv_venv_create."
  fi
  DARTDOC_BUILD_PYTHON="${python}"
  export DARTDOC_BUILD_PYTHON
}

# Generation: the commands are caller arrays, so this file knows neither flutter nor dart.
dartdoc_build_generate() {
  local root
  local -a clean_cmd=() doc_cmd=()
  root="$(_dartdoc_build_root)"
  if [[ -n "${DARTDOC_BUILD_CLEAN_CMD+set}" ]]; then
    clean_cmd=("${DARTDOC_BUILD_CLEAN_CMD[@]}")
  fi
  if [[ -n "${DARTDOC_BUILD_DOC_CMD+set}" ]]; then
    doc_cmd=("${DARTDOC_BUILD_DOC_CMD[@]}")
  fi
  if [[ ${#doc_cmd[@]} -eq 0 ]]; then
    doc_cmd=(dart doc)
  fi

  if [[ ${#clean_cmd[@]} -gt 0 ]]; then
    info "Cleaning the build tree: ${clean_cmd[*]}"
    (
      cd "${root}" || exit 1
      "${clean_cmd[@]}"
    )
  fi
  info "Generating API documentation: ${doc_cmd[*]}"
  (
    cd "${root}" || exit 1
    "${doc_cmd[@]}"
  )
}

# Theming: truncate a previous append at the sheet's first line so rebuilds cannot stack copies.
dartdoc_build_apply_theme() {
  local theme api_dir target marker
  theme="${DARTDOC_BUILD_THEME_CSS:-}"
  if [[ -z "${theme}" ]]; then
    err "No theme sheet configured (set DARTDOC_BUILD_THEME_CSS to the generated dartdoc.css)."
  fi
  if [[ ! -f "${theme}" ]]; then
    err "Theme sheet not found: ${theme} (run DocumANTation style/generate_style.py --write)."
  fi
  api_dir="$(_dartdoc_build_require_api_dir)"
  target="${api_dir}/static-assets/styles.css"
  if [[ ! -f "${target}" ]]; then
    err "No dartdoc stylesheet at ${target}; the generated tree is incomplete."
  fi

  marker="$(head -n 1 "${theme}")"
  if grep -qxF -- "${marker}" "${target}"; then
    info "Removing the previous theme append from ${target}"
    awk -v marker="${marker}" '$0 == marker { exit } { print }' "${target}" >"${target}.new"
    mv "${target}.new" "${target}"
  fi
  info "Appending the generated brand theme to ${target}"
  cat "${theme}" >>"${target}"
}

# The brand sheet carries both palettes, and this family's sites open dark.
dartdoc_build_default_dark() {
  local api_dir
  api_dir="$(_dartdoc_build_require_api_dir)"
  info "Making dark mode the default in ${api_dir}"
  find "${api_dir}" -type f -name '*.html' -print0 |
    xargs -0 -r sed -i 's/class="light-theme"/class="dark-theme"/g'
}

# Assets and guide pages
dartdoc_build_copy_images() {
  local images api_dir
  images="${DARTDOC_BUILD_IMAGES_DIR:-}"
  if [[ -z "${images}" ]]; then
    info "No image directory configured; nothing to copy"
    return 0
  fi
  if [[ ! -d "${images}" ]]; then
    err "DARTDOC_BUILD_IMAGES_DIR points at a missing directory: ${images}"
  fi
  api_dir="$(_dartdoc_build_require_api_dir)"
  info "Copying ${images} into ${api_dir}/images"
  mkdir -p "${api_dir}/images"
  cp -a "${images}/." "${api_dir}/images/"
}

# <fields> <shape> <setting> <entries>...; the one | splitter, whose last field absorbs further |.
_dartdoc_build_split() {
  local want="$1" shape="$2" name="$3" entry a b c
  shift 3
  for entry in "$@"; do
    c=""
    if [[ "${want}" -eq 3 ]]; then
      IFS='|' read -r a b c <<<"${entry}"
    else
      IFS='|' read -r a b <<<"${entry}"
    fi
    if [[ -z "${a}" || -z "${b}" ]] || { [[ "${want}" -eq 3 ]] && [[ -z "${c}" ]]; }; then
      err "${name} entry must be '${shape}', got: ${entry}"
    fi
    printf '%s\t%s\t%s\n' "${a}" "${b}" "${c}"
  done
}

# Entries are <source>|<slug>|<nav title>; the slug names the staged md and guide-<slug>.html.
_dartdoc_build_guide_rows() {
  _dartdoc_build_split 3 '<path>|<slug>|<title>' DARTDOC_BUILD_GUIDES \
    ${DARTDOC_BUILD_GUIDES[@]+"${DARTDOC_BUILD_GUIDES[@]}"}
}

dartdoc_build_stage_guides() {
  local api_dir md_dir rows src slug
  api_dir="$(_dartdoc_build_require_api_dir)"
  md_dir="${api_dir}/md"
  mkdir -p "${md_dir}"
  rm -f "${api_dir}"/guide-*.html
  # Collected first so err() exits the script, not a process-substitution subshell.
  rows="$(_dartdoc_build_guide_rows)" || exit 1
  while IFS=$'\t' read -r src slug _; do
    [[ -n "${src}" ]] || continue
    if [[ ! -f "${src}" ]]; then
      err "Guide source not found: ${src} (listed in DARTDOC_BUILD_GUIDES)."
    fi
    cp "${src}" "${md_dir}/${slug}.md"
  done <<<"${rows}"
  info "Staged the configured Markdown guides under ${md_dir}"
}

# Tab-separated, so titles and labels may hold any character without shell quoting.
_dartdoc_build_write_render_config() {
  local out rows
  out="$1"
  : >"${out}"
  printf 'title_suffix\t%s\n' "${DARTDOC_BUILD_TITLE_SUFFIX:-}" >>"${out}"
  printf 'footer_title\t%s\n' "${DARTDOC_BUILD_FOOTER_TITLE:-}" >>"${out}"
  rows="$(_dartdoc_build_guide_rows)" || exit 1
  printf '%s\n' "${rows}" |
    awk -F'\t' 'NF { printf "guide\t%s\t%s\n", $2, $3 }' >>"${out}"
  rows="$(_dartdoc_build_split 2 '<label>|<url>' DARTDOC_BUILD_FOOTER_LINKS \
    ${DARTDOC_BUILD_FOOTER_LINKS[@]+"${DARTDOC_BUILD_FOOTER_LINKS[@]}"})" || exit 1
  printf '%s\n' "${rows}" |
    awk -F'\t' 'NF { printf "footer\t%s\t%s\n", $1, $2 }' >>"${out}"
}

dartdoc_build_render_guides() {
  local api_dir python config
  api_dir="$(_dartdoc_build_require_api_dir)"
  python="${DARTDOC_BUILD_PYTHON:-python3}"
  config="$(mktemp)"
  _dartdoc_build_write_render_config "${config}"
  info "Rendering the Markdown guides and navigation into ${api_dir}"
  if ! "${python}" "${_DARTDOC_BUILD_LIB_DIR}/dartdoc-guides.py" "${api_dir}" "${config}"; then
    rm -f "${config}"
    err "dartdoc-guides.py failed; the documentation tree is incomplete."
  fi
  rm -f "${config}"
}

# Ownership: root wrote doc/ over a bind mount, so a failing chown is a real failure.
dartdoc_build_fix_ownership() {
  local root doc_root owner_uid owner_gid
  if [[ "${CI:-}" != "true" ]]; then
    info "Not in CI; leaving documentation ownership alone"
    return 0
  fi
  root="$(_dartdoc_build_root)"
  doc_root="$(_dartdoc_build_doc_root)"
  owner_uid="$(stat -c '%u' "${root}")"
  owner_gid="$(stat -c '%g' "${root}")"
  info "Restoring ownership of ${doc_root} to ${owner_uid}:${owner_gid}"
  chown -R "${owner_uid}:${owner_gid}" "${doc_root}"
}

# Full pipeline: generate, theme, stage and render the guides, fix ownership.
dartdoc_build_main() {
  dartdoc_build_generate
  dartdoc_build_apply_theme
  dartdoc_build_default_dark
  dartdoc_build_copy_images
  dartdoc_build_stage_guides
  dartdoc_build_prepare_python_env
  dartdoc_build_render_guides
  dartdoc_build_fix_ownership
  info "Dartdoc site build completed successfully"
}
