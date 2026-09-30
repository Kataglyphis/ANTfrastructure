#!/usr/bin/env bash
# 01-core modules may only source down this layer table; see docs/cross-build-verification.md#the-01-core-source-graph-is-layered
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE_DIR="${TESTS_DIR}/../01-core"

L0=(logging.sh load-versions-env.sh path-helpers.sh platform.sh guard-helpers.sh)
L1=(arch-mapping.sh ubuntu-mirror.sh downloads.sh parallelism.sh)
L2=(common.sh)
L3=(cross-env.sh cross-gcc.sh cross-python.sh cross-apt.sh cross-meson.sh)
CROSS_ENV_EXTRA=(cross-gcc.sh cross-python.sh cross-apt.sh cross-meson.sh)

# _sourced_sh_basenames <file>: sourced *.sh basenames, comments stripped because some mention aggregators.
_sourced_sh_basenames() {
  sed 's/#.*$//' "$1" \
    | grep -oE '(^|[;&|[:space:]{(])(source|\.)[[:space:]]+[^;&|[:space:]]*\.sh' \
    | grep -oE '[A-Za-z0-9._-]+\.sh$' \
    | sort -u
}

# _assert_layer <file-basename> <allowed-basenames-as-one-string>
_assert_layer() {
  local file="$1" allowed=" $2 " sourced bad="" s
  t_assert_ok test -f "${CORE_DIR}/${file}"
  sourced="$(_sourced_sh_basenames "${CORE_DIR}/${file}" 2>/dev/null || true)"
  for s in ${sourced}; do
    case "${allowed}" in
      *" ${s} "*) ;;
      *) bad="${bad}${s} " ;;
    esac
  done
  t_assert_eq "" "${bad}" \
    "${file} sources module(s) outside its allowed layers: ${bad}"
}

t_case "L0 leaves source no other 01-core module"
for f in "${L0[@]}"; do
  _assert_layer "${f}" ""
done

t_case "L1 modules source only L0"
for f in "${L1[@]}"; do
  _assert_layer "${f}" "${L0[*]}"
done

t_case "common.sh (L2) sources only L0/L1"
for f in "${L2[@]}"; do
  _assert_layer "${f}" "${L0[*]} ${L1[*]}"
done

t_case "L3 cross modules source only L0/L1/L2 (cross-env.sh may also aggregate its cross-* siblings)"
for f in "${L3[@]}"; do
  allowed="${L0[*]} ${L1[*]} ${L2[*]}"
  if [ "${f}" = "cross-env.sh" ]; then
    allowed="${allowed} ${CROSS_ENV_EXTRA[*]}"
  fi
  _assert_layer "${f}" "${allowed}"
done

t_case "no 01-core file sources the top-level-only aggregators"
offenders=""
for path in "${CORE_DIR}"/*.sh; do
  if _sourced_sh_basenames "${path}" \
      | grep -qxE 'artifact-common\.sh|lib-orchestrator\.sh'; then
    offenders="${offenders}$(basename "${path}") "
  fi
done
t_assert_eq "" "${offenders}" \
  "artifact-common.sh / lib-orchestrator.sh are top-only aggregators; sourced by: ${offenders}"


# Only this pair: ubuntu-mirror.sh finds platform.sh by a file test in its own dir, which a per-file mount leaves empty.
t_case "a per-file ubuntu-mirror.sh mount also mounts its platform.sh leaf"
_perfile_mount_violations=""
for _df in "${TESTS_DIR}"/../../Dockerfile.*; do
  [ -f "${_df}" ] || continue
  while IFS= read -r _run; do
    # per-file mount == the SOURCE path ends in the .sh itself
    case "${_run}" in *"source=linux/scripts/01-core/ubuntu-mirror.sh"*) ;; *) continue ;; esac
    case "${_run}" in
      *"source=linux/scripts/01-core/platform.sh"*) ;;
      *) _perfile_mount_violations="${_perfile_mount_violations}$(basename "${_df}") " ;;
    esac
  done < <(sed 's/\\$//' "${_df}" \
            | awk '/^RUN/{if(b)print b; b=$0; next} b&&/^[[:space:]]/{b=b" "$0; next} b{print b; b=""} END{if(b)print b}')
done
t_assert_eq "" "${_perfile_mount_violations}" \
  "ubuntu-mirror.sh per-file mount without platform.sh makes is_truthy undefined and the knob a silent no-op: ${_perfile_mount_violations}"


# See docs/failure-modes.md#apt-gpgv-exits-111-after-a-copy---link-into-tmp
t_case "a COPY --link into /tmp restores /tmp's 1777 mode"
_tmp_link_offenders=""
for _df in "${TESTS_DIR}"/../../Dockerfile.*; do
  [ -f "${_df}" ] || continue
  grep -qE '^COPY[[:space:]]+--link[^#]*[[:space:]]/tmp/' "${_df}" || continue
  grep -qE 'chmod[[:space:]]+1777[[:space:]]+/tmp' "${_df}" \
    || _tmp_link_offenders="${_tmp_link_offenders}$(basename "${_df}") "
done
t_assert_eq "" "${_tmp_link_offenders}" \
  "COPY --link into /tmp without a later chmod 1777 /tmp silently breaks apt for every descendant image: ${_tmp_link_offenders}"

t_summary
