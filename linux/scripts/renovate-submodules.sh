#!/usr/bin/env bash
# Remote HEAD, not .gitmodules branch, is the owner's requested update target.

GIT_BIN=git; GIT_TARGET=""
SUBMODULE_ROOT_REAL=""; SUB_QUERY_REF=""; SUB_QUERY_SHA=""

submodule_default_query() {
  local directory="$1" remote="$2" answer left right
  SUB_QUERY_REF=""; SUB_QUERY_SHA=""
  answer="$("${GIT_BIN}" -C "${directory}" ls-remote --symref --exit-code -- "${remote}" HEAD 2>/dev/null)" \
    || return 1
  while IFS=$'\t' read -r left right; do
    if [[ "${left}" == 'ref: refs/heads/'* && "${right}" == HEAD ]]; then
      SUB_QUERY_REF="${left#ref: }"
    elif [[ "${left}" =~ ^[0-9a-fA-F]{40,64}$ && "${right}" == HEAD ]]; then
      SUB_QUERY_SHA="${left,,}"
    fi
  done <<<"${answer}"
  [ -n "${SUB_QUERY_REF}" ] && [ -n "${SUB_QUERY_SHA}" ] || return 1
  return 0
}

submodule_remote_url() {
  local name="$1" url parent
  url="$(git -C "${TARGET}" config --get "submodule.${name}.url" 2>/dev/null || true)"
  [ -n "${url}" ] || url="$(git -C "${TARGET}" config -f .gitmodules --get "submodule.${name}.url" 2>/dev/null)" \
    || err "cannot read .gitmodules URL for ${name}"
  [ -n "${url}" ] || err "empty .gitmodules URL for ${name}"
  case "${url}" in
    ../*|./*)
      parent="$(git -C "${TARGET}" remote get-url origin 2>/dev/null)" \
        || err "cannot resolve relative submodule URL without parent origin"
      "${PY_BIN}" -c 'import posixpath,sys,urllib.parse
base,rel=sys.argv[1:]
if "://" in base:
    parts=urllib.parse.urlsplit(base)
    print(urllib.parse.urlunsplit(parts._replace(path=posixpath.normpath(parts.path+"/"+rel))))
elif ":" in base and not base.startswith("/"):
    host,path=base.split(":",1)
    print(host+":"+posixpath.normpath(path+"/"+rel))
else:
    print(posixpath.normpath(base+"/"+rel))' "${parent}" "${url}" \
        || err "cannot resolve relative submodule URL for ${name}" ;;
    *) printf '%s\n' "${url}" ;;
  esac
}

submodule_checkout_dir() {
  local path="$1" child="${TARGET}/$1" physical top
  [ -e "${child}/.git" ] || return 1
  [ ! -L "${child}" ] || err "submodule ${path} is a symlink"
  physical="$(cd "${child}" && pwd -P)" || err "cannot enter submodule ${path}"
  [ "${physical}" = "${SUBMODULE_ROOT_REAL}/${path}" ] \
    || err "submodule ${path} resolves away from its tracked path"
  top="$(git -C "${child}" rev-parse --show-toplevel 2>/dev/null)" \
    || err "${path} is not an initialized Git checkout"
  [ "$(cd "${top}" && pwd -P)" = "${physical}" ] \
    || err "${path} is not its own submodule checkout"
}

validate_direct_gitlink() {
  local directory="$1" path="$2" record meta indexed_path mode _ stage
  case "${path}" in *$'\t'*|*$'\n'*) err "submodule path has an unsupported control character" ;; esac
  record="$(git -C "${directory}" ls-files --stage -- ":(literal)${path}")" \
    || err "cannot read gitlink for ${path}"
  IFS=$'\t' read -r meta indexed_path <<<"${record}"
  IFS=' ' read -r mode _ stage <<<"${meta}"
  [ "${mode}" = 160000 ] && [ "${stage}" = 0 ] && [ "${indexed_path}" = "${path}" ] \
    || err ".gitmodules names ${path}, but it is not one tracked gitlink"
}

validate_uninitialized_path() {
  local path="$1" child="${TARGET}/$1" parent physical_parent contents relative_parent
  [ ! -L "${child}" ] || err "uninitialized submodule ${path} is a symlink"
  parent="$(dirname "${child}")"
  while [ ! -d "${parent}" ]; do
    [ ! -e "${parent}" ] && [ ! -L "${parent}" ] \
      || err "uninitialized submodule ${path} has a non-directory parent"
    parent="$(dirname "${parent}")"
  done
  physical_parent="$(cd "${parent}" && pwd -P)" \
    || err "cannot resolve parent of uninitialized submodule ${path}"
  relative_parent="${parent:${#TARGET}}"
  [ "${physical_parent}" = "${SUBMODULE_ROOT_REAL}${relative_parent}" ] \
    || err "uninitialized submodule ${path} resolves away from its tracked path"
  if [ -d "${child}" ]; then
    contents="$(ls -A "${child}")" \
      || err "cannot inspect uninitialized submodule ${path}"
    [ -z "${contents}" ] \
      || err "uninitialized submodule ${path} has files; refusing to replace them"
  fi
}

scan_default_submodule_one() {
  local directory="$1" name="$2" path="$3" checked pinned url initialized
  local child="${TARGET}/$3"
  validate_direct_gitlink "${directory}" "${path}"
  initialized=0
  if [ -e "${child}/.git" ]; then
    submodule_checkout_dir "${path}"
    checked="$(git -C "${child}" rev-parse HEAD 2>/dev/null)" \
      || err "cannot read checked-out commit of ${path}"
    url=origin
    initialized=1
  else
    validate_uninitialized_path "${path}"
    checked=-
    url="$(submodule_remote_url "${name}")" \
      || err "cannot resolve remote URL for submodule ${path}"
  fi
  pinned="$(git -C "${TARGET}" rev-parse "HEAD:${path}" 2>/dev/null)" \
    || err "cannot read committed gitlink of ${path}"
  if [ "${initialized}" -eq 1 ]; then
    submodule_default_query "${child}" "${url}" \
      || err "cannot read remote default HEAD for ${path}; nothing was written"
  else
    submodule_default_query "${TARGET}" "${url}" \
      || err "cannot read remote default HEAD for ${path}; nothing was written"
  fi
  rl_has "${path}" ${SUBMODULE_PATHS[@]+"${SUBMODULE_PATHS[@]}"} \
    && err "duplicate .gitmodules path ${path}"
  SUBMODULE_PATHS+=("${path}"); SUBMODULE_REFS+=("${SUB_QUERY_REF}")
  SUBMODULE_TIPS+=("${SUB_QUERY_SHA}"); SUBMODULE_CHECKED+=("${checked}")
  SUBMODULE_PINNED+=("${pinned}"); SUBMODULE_URLS+=("${url}")
  if { [ "${#SELECTED_SUBMODULES[@]}" -eq 0 ] || rl_has "${path}" "${SELECTED_SUBMODULES[@]}"; } \
    && { [ "${checked}" != "${SUB_QUERY_SHA}" ] || [ "${pinned}" != "${SUB_QUERY_SHA}" ]; }; then
    APPLY_PATHS+=("${path}"); APPLY_REFS+=("${SUB_QUERY_REF}")
    APPLY_TIPS+=("${SUB_QUERY_SHA}"); APPLY_URLS+=("${url}")
    APPLY_INITIALIZED+=("${initialized}")
  fi
}

scan_default_submodules() {
  SUBMODULE_PATHS=(); SUBMODULE_REFS=(); SUBMODULE_TIPS=()
  SUBMODULE_CHECKED=(); SUBMODULE_PINNED=(); SUBMODULE_URLS=()
  APPLY_PATHS=(); APPLY_REFS=(); APPLY_TIPS=(); APPLY_URLS=(); APPLY_INITIALIZED=()
  case ",${MANAGERS}," in
    *,git-submodules,*) ;;
    *) [ "${#SELECTED_SUBMODULES[@]}" -eq 0 ] || err "--submodule-path requires the git-submodules manager"; return 0 ;;
  esac
  SUBMODULE_ROOT_REAL="$(cd "${TARGET}" && pwd -P)"
  local tracked
  tracked="$(git -C "${TARGET}" ls-files --stage | awk '$1 == "160000" { n++ } END { print n+0 }')" \
    || err "cannot count tracked submodule gitlinks"
  if [ ! -f "${TARGET}/.gitmodules" ]; then
    [ "${tracked}" -eq 0 ] || err "${tracked} tracked gitlinks but no .gitmodules; refusing an incomplete submodule scan"
    [ "${#SELECTED_SUBMODULES[@]}" -eq 0 ] || err "unknown direct submodule path: ${SELECTED_SUBMODULES[0]}"
    return 0
  fi
  git -C "${TARGET}" config -f .gitmodules --list >/dev/null \
    || err "cannot parse ${TARGET}/.gitmodules"
  for_each_renovate_submodule "${TARGET}" scan_default_submodule_one
  [ "${tracked}" -eq "${#SUBMODULE_PATHS[@]}" ] \
    || err "${tracked} tracked gitlinks but ${#SUBMODULE_PATHS[@]} valid .gitmodules entries; refusing an incomplete submodule scan"
  local selected
  for selected in ${SELECTED_SUBMODULES[@]+"${SELECTED_SUBMODULES[@]}"}; do
    rl_has "${selected}" "${SUBMODULE_PATHS[@]}" || err "unknown direct submodule path: ${selected}"
  done
}

submodule_target_is_planned() {
  local i="$1" directory="$2" remote="$3"
  submodule_default_query "${directory}" "${remote}" || return 1
  [ "${SUB_QUERY_REF}" = "${APPLY_REFS[i]}" ] \
    && [ "${SUB_QUERY_SHA}" = "${APPLY_TIPS[i]}" ] || return 1
  return 0
}

submodule_fetch_tip() {
  local child="$1" i="$2"
  "${GIT_BIN}" -C "${child}" fetch --quiet --no-tags origin HEAD || return 1
  "${GIT_BIN}" -C "${child}" cat-file -e "${APPLY_TIPS[i]}^{commit}" || return 1
  submodule_target_is_planned "${i}" "${child}" origin || return 1
  return 0
}

for_each_pending_submodule() {
  local action="$1" i
  for ((i=0; i<${#APPLY_PATHS[@]}; i++)); do
    "${action}" "${i}"
  done
}

print_default_submodule_target() {
  local i="$1"
  note "  ${APPLY_PATHS[i]} -> ${APPLY_REFS[i]#refs/heads/} ${APPLY_TIPS[i]}"
}

report_default_submodules() {
  case ",${MANAGERS}," in *,git-submodules,*) ;; *) return 0 ;; esac
  note ""
  note "SUBMODULES - live origin default HEAD, independent of .gitmodules branch:"
  [ "${#SUBMODULE_PATHS[@]}" -gt 0 ] || { note "  none declared"; return 0; }
  printf '%-34s %-12s %-12s %-18s %s\n' PATH CHECKED PINNED DEFAULT_BRANCH TARGET
  local i status
  for ((i=0; i<${#SUBMODULE_PATHS[@]}; i++)); do
    status=current
    if [ "${SUBMODULE_CHECKED[i]}" != "${SUBMODULE_TIPS[i]}" ] \
      || [ "${SUBMODULE_PINNED[i]}" != "${SUBMODULE_TIPS[i]}" ]; then status=update; fi
    if [ "${#SELECTED_SUBMODULES[@]}" -gt 0 ] && ! rl_has "${SUBMODULE_PATHS[i]}" "${SELECTED_SUBMODULES[@]}"; then
      status="${status}, excluded"
    fi
    printf '%-34s %-12s %-12s %-18s %s  (%s)\n' \
      "${SUBMODULE_PATHS[i]}" "${SUBMODULE_CHECKED[i]:0:12}" \
      "${SUBMODULE_PINNED[i]:0:12}" "${SUBMODULE_REFS[i]#refs/heads/}" \
      "${SUBMODULE_TIPS[i]}" "${status}"
  done
}

prefetch_default_submodule_one() {
  local i="$1" child="${GIT_TARGET}/${APPLY_PATHS[$1]}"
  if [ "${APPLY_INITIALIZED[i]}" -eq 0 ]; then
    submodule_target_is_planned "${i}" "${GIT_TARGET}" "${APPLY_URLS[i]}" \
      || err "remote default HEAD moved for ${APPLY_PATHS[i]}; rerun to plan its new tip"
    return 0
  fi
  submodule_fetch_tip "${child}" "${i}" \
    || err "cannot fetch planned default HEAD for ${APPLY_PATHS[i]}; nothing was written"
}

prefetch_default_submodules() { for_each_pending_submodule prefetch_default_submodule_one; }

apply_default_submodule_one() {
  local i="$1" child="${GIT_TARGET}/${APPLY_PATHS[$1]}"
  if [ "${APPLY_INITIALIZED[i]}" -eq 0 ]; then
    "${GIT_BIN}" -C "${GIT_TARGET}" submodule update --init -- "${APPLY_PATHS[i]}" \
      || undo_run "submodule initialization failed for ${APPLY_PATHS[i]}"
    [ -e "${TARGET}/${APPLY_PATHS[i]}/.git" ] \
      || undo_run "submodule initialization did not create ${APPLY_PATHS[i]}"
    submodule_fetch_tip "${child}" "${i}" \
      || undo_run "cannot fetch planned default HEAD for ${APPLY_PATHS[i]}"
  fi
  submodule_target_is_planned "${i}" "${child}" origin \
    || undo_run "remote default HEAD moved for ${APPLY_PATHS[i]}"
  "${GIT_BIN}" -C "${child}" checkout --quiet --no-overwrite-ignore --detach "${APPLY_TIPS[i]}" \
    || undo_run "submodule checkout failed for ${APPLY_PATHS[i]}"
  [ "$("${GIT_BIN}" -C "${child}" rev-parse HEAD 2>/dev/null)" = "${APPLY_TIPS[i]}" ] \
    || undo_run "submodule checkout did not reach ${APPLY_TIPS[i]} for ${APPLY_PATHS[i]}"
  print_default_submodule_target "${i}"
}

apply_default_submodules() {
  [ "${#APPLY_PATHS[@]}" -gt 0 ] || return 0
  note ""
  note "updating ${#APPLY_PATHS[@]} submodule(s) to their origin default HEAD:"
  for_each_pending_submodule apply_default_submodule_one
  "${GIT_BIN}" -C "${GIT_TARGET}" submodule summary -- "${APPLY_PATHS[@]}" 2>/dev/null || true
}
