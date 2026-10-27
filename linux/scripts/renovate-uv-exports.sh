#!/usr/bin/env bash
# Refresh declared uv compatibility files inside Renovate's existing transaction.
[ -n "${_RENOVATE_UV_EXPORTS_LOADED:-}" ] && return 0
_RENOVATE_UV_EXPORTS_LOADED=1

UV_EXPORT_ROWS=(); UV_EXPORT_PATHS=(); UV_EXPORT_TEMP=""

uv_export_locked_to_file() {
  (cd "$1" && env -u UV_NO_GROUP -u UV_NO_DEFAULT_GROUPS -u UV_NO_DEV -u UV_WORKING_DIR \
    uv export --project "$2" --locked --no-dev --no-default-groups --no-emit-project --no-header --no-annotate \
    --format requirements-txt --output-file "$3" >/dev/null)
}

uv_export_select_lock() {
  [ "$1" = uv ] || return 0
  local row project output lock
  for row in ${UV_EXPORT_CONFIG[@]+"${UV_EXPORT_CONFIG[@]}"}; do
    IFS='|' read -r project output <<<"${row}"
    lock="${project}/uv.lock"; [ "${project}" != . ] || lock=uv.lock
    [ "$4" = "${lock}" ] || continue
    rl_has "${output}" ${UV_EXPORT_PATHS[@]+"${UV_EXPORT_PATHS[@]}"} && continue
    rl_has "${output}" ${EDIT_FILES[@]+"${EDIT_FILES[@]}"} && err "generated uv export ${output} has an independent planned edit; disable its separate manager"
    UV_EXPORT_ROWS+=("${row}"); UV_EXPORT_PATHS+=("${output}")
  done
}

plan_uv_exports() {
  local result project output
  UV_EXPORT_ROWS=(); UV_EXPORT_PATHS=(); UV_EXPORT_CONFIG=()
  result="$(rl_py uv-exports "${TARGET}")" || err "cannot validate uv compatibility exports; nothing written"
  while IFS=$'\t' read -r project output; do
    [ -n "${project}" ] || continue
    UV_EXPORT_CONFIG+=("${project}|${output}")
  done <<<"${result}"
  for_each_lock uv_export_select_lock
}

assert_uv_exports_tracked() {
  local path
  path=.github/renovate-uv-exports.json
  if [ -e "${TARGET}/${path}" ] || [ -L "${TARGET}/${path}" ]; then
    "${GIT_BIN}" -C "${GIT_TARGET}" ls-files --error-unmatch -- "${path}" >/dev/null 2>&1 \
      || err "uv export configuration or output is not tracked: ${path}; nothing written"
  fi
  "${GIT_BIN}" -C "${GIT_TARGET}" diff --quiet HEAD -- "${path}" \
    || err "uv export configuration has local changes; nothing written"
  for path in ${UV_EXPORT_PATHS[@]+"${UV_EXPORT_PATHS[@]}"}; do
    "${GIT_BIN}" -C "${GIT_TARGET}" ls-files --error-unmatch -- "${path}" >/dev/null 2>&1 \
      || err "uv export configuration or output is not tracked: ${path}; nothing written"
  done
}

refresh_uv_exports() {
  local row project output tmp
  for row in ${UV_EXPORT_ROWS[@]+"${UV_EXPORT_ROWS[@]}"}; do
    IFS='|' read -r project output <<<"${row}"
    tmp="$(mktemp "${TARGET}/${output}.XXXXXX")" || return 1
    UV_EXPORT_TEMP="${tmp}"
    if ! uv_export_locked_to_file "${TARGET}" "${project}" "${tmp}" || [ ! -s "${tmp}" ]; then
      if rm -f "${tmp}"; then UV_EXPORT_TEMP=""; fi
      return 1
    fi
    if ! cmp -s "${tmp}" "${TARGET}/${output}"; then
      chmod 644 "${tmp}" && mv -f -- "${tmp}" "${TARGET}/${output}" || return 1
    else
      rm -f "${tmp}" || return 1
    fi
    # shellcheck disable=SC2034
    UV_EXPORT_TEMP=""
    note "  uv export: ${project} -> ${output}"
  done
}
