#!/usr/bin/env bash
# gstreamer-env.sh copied with /opt/scripts/core repointed at a fixture; see docs/cross-build-verification.md#gstreamer-envsh-the-runtime-env-the-entrypoint-sources
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../04-runtime/gstreamer-env.sh"

# _env <triplet|none> <helpers yes|no> <dpkg triplet|fail> <var>...: VAR=value lines, then SYSTEM_LIB_SET.
_env() {
  local platform="$1" helpers="$2" dpkg="$3" times="${_ENV_TIMES:-1}"; shift 3
  local d core out status=0
  d="$(mktemp -d)"; core="${d}/core"
  mkdir -p "${core}" "${d}/bin" "${d}/01-core" "${d}/04-runtime"
  [ "${platform}" = "none" ] || \
    printf 'deb_multiarch_triplet() { printf "%%s" "%s"; }\n' "${platform}" > "${core}/platform.sh"
  if [ "${helpers}" = "yes" ]; then
    cp "${TESTS_DIR}/../01-core/path-helpers.sh" "${core}/path-helpers.sh"
  elif [ "${helpers}" = "no" ]; then
    cp "${TESTS_DIR}/../01-core/path-helpers.sh" "${d}/01-core/path-helpers.sh"
  fi
  if [ "${dpkg}" = "fail" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "${d}/bin/dpkg-architecture"
  else
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "${dpkg}" > "${d}/bin/dpkg-architecture"
  fi
  chmod +x "${d}/bin/dpkg-architecture"
  sed "s#/opt/scripts/core#${core}#g" "${SUBJECT}" > "${d}/04-runtime/gstreamer-env.sh"
  out="$(PATH="${d}/bin:${PATH}" GSTREAMER_PREFIX=/opt/gstreamer \
    PKG_CONFIG_PATH="" LD_LIBRARY_PATH="" GST_PLUGIN_PATH="" GI_TYPELIB_PATH="" \
    bash -c 'for _i in $(seq 1 "$2"); do source "$1" >/dev/null 2>&1 || exit $?; done
             for v in "${@:3}"; do printf "%s=%s\n" "${v}" "${!v-}"; done
             printf "SYSTEM_LIB_SET=%s\n" "${SYSTEM_LIB+yes}"' _ "${d}/04-runtime/gstreamer-env.sh" "${times}" "$@")" || status=$?
  rm -rf "${d}"
  printf '%s\n' "${out}"
  return "${status}"
}
_val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

t_case "the platform.sh triplet wins and drives every multiarch path"
res="$(_env aarch64-linux-gnu yes x86_64-linux-gnu MULTIARCH_DIR PKG_CONFIG_PATH LD_LIBRARY_PATH GST_PLUGIN_PATH GI_TYPELIB_PATH)"
t_assert_eq "lib/aarch64-linux-gnu" "$(_val "${res}" MULTIARCH_DIR)"
t_assert_contains "$(_val "${res}" GST_PLUGIN_PATH)" "/opt/gstreamer/lib/aarch64-linux-gnu/gstreamer-1.0" \
  "the multiarch plugin dir is what smoke-runtime-image.sh looks for"
t_assert_contains "$(_val "${res}" GST_PLUGIN_PATH)" "/opt/gstreamer/lib/gstreamer-1.0" \
  "and the plain lib dir stays beside it"
t_assert_contains "$(_val "${res}" PKG_CONFIG_PATH)" "/opt/gstreamer/lib/aarch64-linux-gnu/pkgconfig"
t_assert_contains "$(_val "${res}" LD_LIBRARY_PATH)" "/opt/gstreamer/lib/aarch64-linux-gnu"
t_assert_contains "$(_val "${res}" GI_TYPELIB_PATH)" "/opt/gstreamer/lib/aarch64-linux-gnu/girepository-1.0"

t_case "no platform.sh: the triplet comes from dpkg-architecture"
res="$(_env none yes riscv64-linux-gnu MULTIARCH_DIR)"
t_assert_eq "lib/riscv64-linux-gnu" "$(_val "${res}" MULTIARCH_DIR)"

t_case "no triplet from either source: the multiarch fallback dir"
res="$(_env none yes fail MULTIARCH_DIR GST_PLUGIN_PATH)"
t_assert_eq "lib/multiarch" "$(_val "${res}" MULTIARCH_DIR)"
t_assert_contains "$(_val "${res}" GST_PLUGIN_PATH)" "/opt/gstreamer/lib/multiarch/gstreamer-1.0"

t_case "repository and installed layouts use the same path module"
with="$(_env aarch64-linux-gnu yes fail PKG_CONFIG_PATH LD_LIBRARY_PATH GST_PLUGIN_PATH GI_TYPELIB_PATH)"
without="$(_env aarch64-linux-gnu no fail PKG_CONFIG_PATH LD_LIBRARY_PATH GST_PLUGIN_PATH GI_TYPELIB_PATH)"
t_assert_eq "${with}" "${without}" "both layouts must preserve path order and idempotence"

t_case "sourcing twice does not duplicate an entry (the _path_prepend_unique contract)"
once="$(_env aarch64-linux-gnu yes fail GST_PLUGIN_PATH)"
twice="$(_ENV_TIMES=2 _env aarch64-linux-gnu yes fail GST_PLUGIN_PATH)"
t_assert_eq "$(_val "${once}" GST_PLUGIN_PATH)" "$(_val "${twice}" GST_PLUGIN_PATH)"
t_assert_eq "1" "$(_val "${twice}" GST_PLUGIN_PATH | tr ':' '\n' | grep -c -e '^/opt/gstreamer/lib/gstreamer-1.0$')"

t_case "SYSTEM_LIB is gone: nothing ever read it (CL6)"
t_assert_eq "SYSTEM_LIB_SET=" "$(_env aarch64-linux-gnu yes fail | tail -1)"
t_assert_eq "SYSTEM_LIB_SET=" "$(_env none yes fail | tail -1)" "the fallback branch too"

t_case "missing shared helpers fail before claiming an initialized environment"
t_assert_eq 1 "$(t_rc _env none missing fail GST_PLUGIN_PATH)"

_camera_env() {
  local camera_fixture out
  camera_fixture="$(mktemp -d)"
  mkdir -p "${camera_fixture}/lib/pkgconfig" "${camera_fixture}/lib/gstreamer-1.0" "${camera_fixture}/bin"
  out="$(
    export LD_LIBRARY_PATH=/host/libcamera PKG_CONFIG_PATH=/host/pkgconfig GST_PLUGIN_PATH=/host/plugins
    source "${TESTS_DIR}/../04-runtime/libcamera-env.sh" "${camera_fixture}"
    source "${TESTS_DIR}/../04-runtime/libcamera-env.sh" "${camera_fixture}"
    printf '%s\n' "${LD_LIBRARY_PATH}" "${PKG_CONFIG_PATH}" "${GST_PLUGIN_PATH}"
  )"
  printf '%s\n' "${out}" | sed "s#${camera_fixture}#PREFIX#g"
  rm -rf "${camera_fixture}"
}
t_case "libcamera preserves host precedence and adds each prefix path only once"
res="$(_camera_env)"
t_assert_contains "${res}" '/host/libcamera:PREFIX/lib'
t_assert_contains "${res}" '/host/pkgconfig:PREFIX/lib/pkgconfig'
t_assert_contains "${res}" '/host/plugins:PREFIX/lib/gstreamer-1.0'
t_assert_eq 1 "$(printf '%s\n' "${res}" | tail -1 | tr ':' '\n' | grep -cx 'PREFIX/lib/gstreamer-1.0')"

t_summary
