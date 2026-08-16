#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh   # defines cross_build_is_active
fi

# retag_directory_wheels (and arch_linux_platform_tag_for) live in 01-core
# common.sh — bind-mounted at /opt/scripts/core in the media runtime stage,
# with the repo-relative fallback for host-side runs.
_SCRIPT_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _common in \
  "/opt/scripts/core/common.sh" \
  "${_SCRIPT_DIR_EARLY}/../../01-core/common.sh"; do
  if [ -f "${_common}" ]; then
    # shellcheck disable=SC1090,SC1091
    source "${_common}"
    break
  fi
done
unset _common

# WHEELS_DIR comes from the canonical media-env.sh (sibling of this script).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/media-env.sh"

# AP1: cross wheels ship UNSTRIPPED — `cmake --install --strip` runs the HOST
# strip, a no-op on foreign-arch ELFs (~50-300 MB/arch of dead symbols). Strip
# the .so inside each cross wheel with the target <triplet>-strip. Python wheels
# are zips with a RECORD manifest (path,sha256,size), so we unpack → strip →
# `wheel pack` (which RECOMPUTES RECORD) — never an in-place edit that would
# desync RECORD. Corruption-safe: the original is removed only AFTER a successful
# repack to a temp dir. Best-effort per wheel; MEDIA_STRIP=0 disables. Pure-python
# (*-none-any) wheels have no .so and are skipped.
strip_cross_wheels() {
  [ "${MEDIA_STRIP:-1}" = "1" ] || return 0
  command -v uv >/dev/null 2>&1 || return 0
  declare -F _resolve_media_strip_bin >/dev/null 2>&1 || return 0
  local strip_bin; strip_bin="$(_resolve_media_strip_bin 2>/dev/null || printf 'strip')"
  local whl tmp unpacked packed
  for whl in "${WHEELS_DIR}"/*.whl; do
    [ -f "${whl}" ] || continue
    case "${whl}" in *-none-any.whl) continue ;; esac
    tmp="$(mktemp -d)"
    if uv run python -m wheel unpack "${whl}" -d "${tmp}/u" >/dev/null 2>&1 \
       && find "${tmp}/u" -type f \( -name '*.so' -o -name '*.so.*' \) -print -quit 2>/dev/null | grep -q .; then
      find "${tmp}/u" -type f \( -name '*.so' -o -name '*.so.*' \) \
        -exec "${strip_bin}" --strip-all {} + 2>/dev/null || true
      unpacked="$(find "${tmp}/u" -mindepth 1 -maxdepth 1 -type d | head -1)"
      mkdir -p "${tmp}/p"   # `wheel pack -d` does NOT create its dest dir
      if [ -n "${unpacked}" ] && uv run python -m wheel pack "${unpacked}" -d "${tmp}/p" >/dev/null 2>&1; then
        packed="$(find "${tmp}/p" -maxdepth 1 -name '*.whl' | head -1)"
        if [ -n "${packed}" ]; then
          rm -f "${whl}"
          mv -f "${packed}" "${WHEELS_DIR}/$(basename "${packed}")"
          echo "  AP1: stripped + repacked $(basename "${packed}")"
        fi
      fi
    fi
    rm -rf "${tmp}"
  done
}

if cross_build_is_active; then
  # AP1: strip cross wheels BEFORE retagging (retag then normalizes the tag on
  # the repacked wheels).
  strip_cross_wheels
  target_arch="$(cross_target_arch 2>/dev/null || true)"
  [ -n "${target_arch}" ] || target_arch="${TARGET_ARCH:-}"
  if [ -n "${target_arch}" ] && command -v arch_linux_platform_tag_for >/dev/null 2>&1 \
      && command -v retag_directory_wheels >/dev/null 2>&1; then
    platform_tag="$(arch_linux_platform_tag_for "${target_arch}")"
    if [ -n "${platform_tag}" ]; then
      echo "Retagging cross-built wheels for platform: ${platform_tag}"
      # Canonical helper (01-core/common.sh); skips *-none-any.whl and
      # already-tagged wheels, exactly like the hand-rolled loop it replaced.
      retag_directory_wheels "${WHEELS_DIR}" "*" "${platform_tag}" uv run python
    fi
  fi
  echo "Cross-build wheel retagging complete"
  exit 0
fi

# Native build: run auditwheel repair, skip if auditwheel fails
echo "Running auditwheel repair on native wheels..."
REPAIRED_WHEELS_DIR="${WHEELS_DIR}/repaired"

# Executor pins per supply-chain audit #18 — auditwheel REWRITES the shipped
# wheels' ELF headers; pinned so the same commit grafts the same RPATHs.
uv pip install "auditwheel==${PY_AUDITWHEEL_VERSION:-6.7.0}" "patchelf==${PY_PATCHELF_VERSION:-0.19.1.0}"
runtime_ld_path="$(find /opt /usr/local -type d \( -name 'lib*' -o -name '*linux-gnu*' \) 2>/dev/null | sort -u | paste -sd ':' - || true)"
export LD_LIBRARY_PATH="${runtime_ld_path}:${LD_LIBRARY_PATH:-}"

mkdir -p "${REPAIRED_WHEELS_DIR}"
_aw_err="$(mktemp)"
trap 'rm -f "${_aw_err}"' EXIT
# The manylinux-retag failure is EXPECTED for every local wheel on resolute (glibc
# newer than any manylinux profile), so accumulate the skipped names and emit ONE
# summary NOTE at the end instead of an identical line per wheel (was N-wheels ×
# 3-arches of noise). An UNEXPECTED failure still surfaces auditwheel's output
# inline per-wheel.
_aw_retag_skipped=()
shopt -s nullglob
for wheel in "${WHEELS_DIR}"/*.whl; do
  case "$(basename "${wheel}")" in
    *none-any.whl)
      cp "${wheel}" "${REPAIRED_WHEELS_DIR}/"
      ;;
    *)
      # auditwheel repair fails on Ubuntu 26.04 (resolute), whose glibc is newer
      # than any manylinux profile ("too-recent versioned symbols"). These are
      # LOCAL wheels consumed in the same image, so the manylinux tag is purely
      # cosmetic -- fall back to the raw wheel. Classify the failure: the EXPECTED
      # case is collected for a single summary NOTE below; an UNEXPECTED failure
      # still surfaces auditwheel's output.
      if ! auditwheel repair "${wheel}" -w "${REPAIRED_WHEELS_DIR}/" 2>"${_aw_err}"; then
        if grep -q 'too-recent versioned symbols' "${_aw_err}"; then
          _aw_retag_skipped+=("$(basename "${wheel}")")
        else
          echo "WARN: auditwheel repair failed unexpectedly for $(basename "${wheel}"); shipping unrepaired wheel. auditwheel said:" >&2
          sed 's/^/    /' "${_aw_err}" >&2
        fi
        cp "${wheel}" "${REPAIRED_WHEELS_DIR}/"
      fi
      ;;
  esac
done
shopt -u nullglob
if [ "${#_aw_retag_skipped[@]}" -gt 0 ]; then
  echo "NOTE: auditwheel cannot retag ${#_aw_retag_skipped[@]} local wheel(s) to manylinux (host glibc newer than the profile); shipping them unrepaired (expected; tag is cosmetic for in-image use): ${_aw_retag_skipped[*]}"
fi

rm -f "${WHEELS_DIR}"/*.whl
# Guard the glob explicitly: under nullglob a zero-match glob degenerates the
# mv to one argument, which aborts the script right after it deleted the
# original wheels.
if compgen -G "${REPAIRED_WHEELS_DIR}/*.whl" > /dev/null; then
  shopt -s nullglob
  mv "${REPAIRED_WHEELS_DIR}"/*.whl "${WHEELS_DIR}/"
  shopt -u nullglob
else
  echo "WARNING: no repaired wheels produced in ${REPAIRED_WHEELS_DIR}" >&2
fi
rmdir "${REPAIRED_WHEELS_DIR}" 2>/dev/null || true
