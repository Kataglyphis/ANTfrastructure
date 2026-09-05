#!/usr/bin/env bash
# Tests for 04-runtime/gstreamer-env.sh — the runtime env script the entrypoint
# sources and smoke-runtime-image.sh checks the effect of. Each case copies the
# script and repoints its /opt/scripts/core lookups at a fixture, so the triplet
# branch, the multiarch fallback and the inline path-helper copy all run here.
# docs/cross-build-verification.md#gstreamer-envsh-the-runtime-env-the-entrypoint-sources
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../04-runtime/gstreamer-env.sh"

# _env <fixture-flags> <var>... — source a repointed copy and print `VAR=value`
# for each named variable, plus SYSTEM_LIB's set-ness as SYSTEM_LIB_SET=yes|no.
# Flags: platform=<triplet>|none, helpers=yes|no, dpkg=<triplet>|fail, times=1|2
_env() {
  local platform="$1" helpers="$2" dpkg="$3" times="${_ENV_TIMES:-1}"; shift 3
  local d core out
  d="$(mktemp -d)"; core="${d}/core"
  mkdir -p "${core}" "${d}/bin"
  [ "${platform}" = "none" ] || \
    printf 'deb_multiarch_triplet() { printf "%%s" "%s"; }\n' "${platform}" > "${core}/platform.sh"
  [ "${helpers}" = "no" ] || \
    cp "${TESTS_DIR}/../01-core/path-helpers.sh" "${core}/path-helpers.sh"
  if [ "${dpkg}" = "fail" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "${d}/bin/dpkg-architecture"
  else
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "${dpkg}" > "${d}/bin/dpkg-architecture"
  fi
  chmod +x "${d}/bin/dpkg-architecture"
  sed "s#/opt/scripts/core#${core}#g" "${SUBJECT}" > "${d}/gstreamer-env.sh"
  out="$(PATH="${d}/bin:${PATH}" GSTREAMER_PREFIX=/opt/gstreamer \
    PKG_CONFIG_PATH="" LD_LIBRARY_PATH="" GST_PLUGIN_PATH="" GI_TYPELIB_PATH="" \
    bash -c 'for _i in $(seq 1 "$2"); do source "$1" >/dev/null 2>&1; done
             for v in "${@:3}"; do printf "%s=%s\n" "${v}" "${!v-}"; done
             printf "SYSTEM_LIB_SET=%s\n" "${SYSTEM_LIB+yes}"' _ "${d}/gstreamer-env.sh" "${times}" "$@")"
  rm -rf "${d}"
  printf '%s\n' "${out}"
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

t_case "the inline path-helper fallback agrees with the shared module"
with="$(_env aarch64-linux-gnu yes fail PKG_CONFIG_PATH LD_LIBRARY_PATH GST_PLUGIN_PATH GI_TYPELIB_PATH)"
without="$(_env aarch64-linux-gnu no fail PKG_CONFIG_PATH LD_LIBRARY_PATH GST_PLUGIN_PATH GI_TYPELIB_PATH)"
t_assert_eq "${with}" "${without}" "the deliberate triplication must stay byte-identical in effect"

t_case "sourcing twice does not duplicate an entry (the _path_prepend_unique contract)"
once="$(_env aarch64-linux-gnu yes fail GST_PLUGIN_PATH)"
twice="$(_ENV_TIMES=2 _env aarch64-linux-gnu yes fail GST_PLUGIN_PATH)"
t_assert_eq "$(_val "${once}" GST_PLUGIN_PATH)" "$(_val "${twice}" GST_PLUGIN_PATH)"
t_assert_eq "1" "$(_val "${twice}" GST_PLUGIN_PATH | tr ':' '\n' | grep -c -e '^/opt/gstreamer/lib/gstreamer-1.0$')"

t_case "SYSTEM_LIB is gone: nothing ever read it (CL6)"
t_assert_eq "SYSTEM_LIB_SET=" "$(_env aarch64-linux-gnu yes fail | tail -1)"
t_assert_eq "SYSTEM_LIB_SET=" "$(_env none yes fail | tail -1)" "the fallback branch too"

t_summary
