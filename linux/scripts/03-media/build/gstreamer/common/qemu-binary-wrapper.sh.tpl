#!/usr/bin/env bash
set -euo pipefail

wrapper_mode='@WRAPPER_MODE@'

[ "$#" -ge 1 ] || exit 2

binary="$1"
shift

target_ld_library_path=""

append_target_libdir() {
  local dir="$1"
  [ -n "${dir}" ] || return 0
  [ -d "${dir}" ] || return 0

  case ":${target_ld_library_path}:" in
    *":${dir}:"*)
      ;;
    *)
      if [ -n "${target_ld_library_path}" ]; then
        target_ld_library_path="${target_ld_library_path}:${dir}"
      else
        target_ld_library_path="${dir}"
      fi
      ;;
  esac
}

append_binary_runpaths() {
  local binary_path="$1"
  local binary_dir objdump_cmd runpath old_ifs entry

  [ -n "${binary_path}" ] || return 0
  [ -f "${binary_path}" ] || return 0

  binary_dir="$(cd "$(dirname "${binary_path}")" 2>/dev/null && pwd)"

  if [ -n "@TARGET_TRIPLET@" ] && command -v "@TARGET_TRIPLET@-objdump" >/dev/null 2>&1; then
    objdump_cmd="@TARGET_TRIPLET@-objdump"
  else
    objdump_cmd="objdump"
  fi

  while IFS= read -r runpath; do
    [ -n "${runpath}" ] || continue

    old_ifs="${IFS}"
    IFS=':'
    for entry in ${runpath}; do
      case "${entry}" in
        '$ORIGIN'|'${ORIGIN}')
          entry="${binary_dir}"
          ;;
        '$ORIGIN'/*|'${ORIGIN}'/*)
          entry="${binary_dir}/${entry#*/}"
          ;;
      esac
      append_target_libdir "${entry}"
    done
    IFS="${old_ifs}"
  done < <("${objdump_cmd}" -p "${binary_path}" | awk '
    /^[[:space:]]*RUNPATH/ || /^[[:space:]]*RPATH/ {
      $1 = ""
      sub(/^[[:space:]]+/, "")
      print
    }
  ')
}

merge_target_libdirs() {
  local value="$1" dir old_ifs
  [ -n "${value}" ] || return 0

  old_ifs="${IFS}"
  IFS=':'
  for dir in ${value}; do
    append_target_libdir "${dir}"
  done
  IFS="${old_ifs}"
}

append_meson_uninstalled_libdirs() {
  local meson_uninstalled="" entry pc_file pkg_name lib_flag
  local old_ifs
  local -a pkg_config_entries

  IFS=':' read -r -a pkg_config_entries <<< "${PKG_CONFIG_PATH:-}"
  for entry in "${pkg_config_entries[@]}"; do
    case "${entry}" in
      */meson-uninstalled)
        meson_uninstalled="${entry}"
        break
        ;;
    esac
  done

  if [ -n "${meson_uninstalled}" ] && [ -d "${meson_uninstalled}" ]; then
    while IFS= read -r pc_file; do
      pkg_name="$(basename "${pc_file}" .pc)"
      for lib_flag in $(pkg-config --libs-only-L "${pkg_name}" 2>/dev/null || true); do
        case "${lib_flag}" in
          -L*)
            append_target_libdir "${lib_flag#-L}"
            ;;
        esac
      done
    done < <(find "${meson_uninstalled}" -maxdepth 1 -type f -name '*.pc' -print)
  fi
}

if [ "${wrapper_mode}" = "gi" ]; then
  # For temporary GIR dump binaries, prefer the current build-tree libraries
  # from meson-uninstalled metadata before broader inherited target paths.
  append_meson_uninstalled_libdirs
  merge_target_libdirs "${LD_LIBRARY_PATH:-}"
  merge_target_libdirs "${GI_TARGET_LD_LIBRARY_PATH:-}"
  merge_target_libdirs "${LIBRARY_PATH:-}"
  append_target_libdir "$(dirname "${binary}")"
else
  # Generic Meson target helpers like orcc need their executable-local
  # RUNPATH/RPATH ahead of broader target library fallbacks.
  append_target_libdir "$(dirname "${binary}")"
  append_binary_runpaths "${binary}"
  append_meson_uninstalled_libdirs
  merge_target_libdirs "${LD_LIBRARY_PATH:-}"
  merge_target_libdirs "${GI_TARGET_LD_LIBRARY_PATH:-}"
  merge_target_libdirs "${LIBRARY_PATH:-}"
fi

if [ -n "@TARGET_TRIPLET@" ]; then
  append_target_libdir "/lib/@TARGET_TRIPLET@"
  append_target_libdir "/usr/lib/@TARGET_TRIPLET@"
fi

qemu_args=( "@QEMU_RUNNER@" -L "@QEMU_SYSROOT@" )
if [ -n "${target_ld_library_path}" ]; then
  qemu_args+=( -E "LD_LIBRARY_PATH=${target_ld_library_path}" )
fi

exec env -u LD_LIBRARY_PATH "${qemu_args[@]}" "${binary}" "$@"
