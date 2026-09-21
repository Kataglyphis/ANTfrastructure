#!/usr/bin/env bash
# Freezes the verified-clean layering of the 01-core source graph.
# docs/cross-build-verification.md#the-01-core-source-graph-is-layered
#
# The 01-core modules form a small DAG that was audited clean; nothing enforces
# it, so a convenience `source common.sh` added to a leaf would silently create
# a cycle / load-order landmine that only detonates inside a Dockerfile stage.
# This suite statically greps the `source` / `. ` lines (comments stripped) of
# each module and asserts it only reaches DOWN the layer table.
#
# Layer table (frozen from today's tree — adjust ONLY when the code's layering
# deliberately changes, and keep it matching reality):
#
#   L0 (true leaves, source NO other 01-core file):
#       logging.sh load-versions-env.sh path-helpers.sh platform.sh guard-helpers.sh
#       NOTE: platform.sh is L0, not L1 as the original A5 sketch guessed —
#       it sources nothing (its own header calls it a "true leaf") and BOTH
#       arch-mapping.sh and ubuntu-mirror.sh source it.
#   L1 (may source only L0):
#       arch-mapping.sh ubuntu-mirror.sh downloads.sh parallelism.sh
#   L2 (may source only L0/L1):
#       common.sh
#   L3 (may source only L0/L1/L2; cross-env.sh is additionally the L3
#       aggregator and sources its four cross-* siblings):
#       cross-env.sh cross-gcc.sh cross-python.sh cross-apt.sh cross-meson.sh
#
# Plus the aggregator rule: NO 01-core file may source artifact-common.sh or
# lib-orchestrator.sh — those are top-level-only aggregators (comments in
# context-management.sh / version-forwarding.sh mention artifact-common.sh,
# which is exactly why this check strips comments first).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE_DIR="${TESTS_DIR}/../01-core"

L0=(logging.sh load-versions-env.sh path-helpers.sh platform.sh guard-helpers.sh)
L1=(arch-mapping.sh ubuntu-mirror.sh downloads.sh parallelism.sh)
L2=(common.sh)
L3=(cross-env.sh cross-gcc.sh cross-python.sh cross-apt.sh cross-meson.sh)
CROSS_ENV_EXTRA=(cross-gcc.sh cross-python.sh cross-apt.sh cross-meson.sh)

# Print the basenames of *.sh files sourced by "$1", comments stripped.
# Catches `source x.sh`, `. x.sh` and the guarded `[ -f x ] && source x` form;
# non-.sh sources (e.g. `. /etc/os-release`) are deliberately ignored.
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


# ── A per-file mount must bring the leaf its script sources ───────────────────
# The layer table proves the graph is clean ON DISK; inside a Dockerfile it can
# still detonate. ubuntu-mirror.sh's defensive platform.sh source is a FILE TEST
# against its own dir, which a PER-FILE mount leaves empty.
# Deliberately NARROW (that one pair, per-file mounts only): a general
# source-closure check reports ~140 false positives, because a whole-directory
# mount already carries every leaf.
# docs/linux-cross-builds.md#non-amd64-build-hosts
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


# ── COPY --link into /tmp must restore /tmp's mode ───────────────────────────
# `COPY --link` merges an INDEPENDENT layer, so the /tmp entry comes from that
# layer's 0755 default instead of the base's 1777. A PLAIN COPY does not (both
# measured 2026-09-16). apt then cannot write as _apt, its gpgv exits 111, and
# the message blames a missing gnupg -- in that image and every one built FROM
# it. docs/linux-cross-builds.md#non-amd64-build-hosts
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
