#!/usr/bin/env bash
# Tests for lib/app-packaging.sh's flatpak half: scope probes, append-only finish args, ostree as the verdict.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="$(cd "${TESTS_DIR}/.." && pwd)/lib/app-packaging.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

BIN="${_work}/bin"
mkdir -p "${BIN}"

# ── stubs ────────────────────────────────────────────────────────────────────
cat > "${BIN}/flatpak" <<'STUB'
#!/usr/bin/env bash
printf 'flatpak %s\n' "$*" >> "${STUB_LOG}"
case "$*" in
  *--default-arch*)            printf '%s\n' "${STUB_DEFAULT_ARCH:-x86_64}"; exit 0 ;;
  "remote-info --user flathub")   exit "${STUB_USER_REMOTE:-1}" ;;
  "remote-info --system flathub") exit "${STUB_SYSTEM_REMOTE:-1}" ;;
  "--user remote-add"*)        exit "${STUB_USER_REMOTE_ADD_RC:-0}" ;;
  "--system remote-add"*)      exit 0 ;;
  "info --user "*)             exit "${STUB_USER_HAS_REF:-1}" ;;
  "info --system "*)           exit "${STUB_SYSTEM_HAS_REF:-1}" ;;
  "--user install"*)           exit "${STUB_USER_INSTALL_RC:-0}" ;;
  "--system install"*)         exit "${STUB_SYSTEM_INSTALL_RC:-0}" ;;
  "build-bundle "*)
    # $2 = repo, $3 = bundle path, $4 = app id, $5 = branch
    if [ "${STUB_EMPTY_BUNDLE:-0}" = "1" ]; then : > "$3"; else printf 'bundle-bytes\n' > "$3"; fi
    exit "${STUB_BUNDLE_RC:-0}" ;;
esac
exit 0
STUB

cat > "${BIN}/flatpak-builder" <<'STUB'
#!/usr/bin/env bash
printf 'flatpak-builder %s\n' "$*" >> "${STUB_LOG}"
exit "${STUB_FB_RC:-0}"
STUB

cat > "${BIN}/ostree" <<'STUB'
#!/usr/bin/env bash
printf 'ostree %s\n' "$*" >> "${STUB_LOG}"
[ "${STUB_OSTREE_EMPTY:-0}" = "1" ] && exit 0
printf 'app/%s/x86_64/master\n' "${STUB_APP_ID:-org.example.app}"
STUB

# Probed with `command -v`; the fixture, not the host, owns the answer.
cat > "${BIN}/dpkg" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "${BIN}/wget" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "${BIN}/dbus-run-session" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--" ] && shift
exec "$@"
STUB

# Installs the binary plus three project-named files to rename; STUB_CMAKE_NO_BIN=1 leaves bin/ empty.
cat > "${BIN}/cmake" <<'STUB'
#!/usr/bin/env bash
printf 'cmake %s\n' "$*" >> "${STUB_LOG}"
[ "${STUB_CMAKE_RC:-0}" != "0" ] && exit "${STUB_CMAKE_RC}"
prefix=""
while [ $# -gt 0 ]; do
  case "$1" in --prefix) prefix="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${prefix}" ] || exit 0
mkdir -p "${prefix}/bin" "${prefix}/share/applications" \
         "${prefix}/share/icons/hicolor/256x256/apps" "${prefix}/share/metainfo"
if [ "${STUB_CMAKE_NO_BIN:-0}" != "1" ]; then
  printf '#!/bin/sh\n' > "${prefix}/bin/${STUB_PROJECT}"
  chmod +x "${prefix}/bin/${STUB_PROJECT}"
fi
printf 'desktop\n'  > "${prefix}/share/applications/${STUB_PROJECT}.desktop"
printf 'png\n'      > "${prefix}/share/icons/hicolor/256x256/apps/${STUB_PROJECT}.png"
printf 'appdata\n'  > "${prefix}/share/metainfo/${STUB_PROJECT}.appdata.xml"
exit 0
STUB

chmod +x "${BIN}/flatpak" "${BIN}/flatpak-builder" "${BIN}/ostree" "${BIN}/cmake" \
  "${BIN}/dpkg" "${BIN}/wget" "${BIN}/dbus-run-session"

APP_ID="org.kataglyphis.accelerantgine"
PROJECT="KataglyphisCppProject"

OUT=""; rc=0; LOG=""; FLATPAK_WORK=""
# _call <env-assignments...> -- <function> <args...>: one library function in its own shell, stubs first on PATH.
_call() {
  local -a env_pairs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do env_pairs+=("$1"); shift; done
  shift
  LOG="$(mktemp "${_work}/log.XXXXXX")"
  FLATPAK_WORK="$(mktemp -d "${_work}/fpwork.XXXXXX")"
  # Every switch has its default here, so none is owned only by a stub or parked in lint-env-knobs.allow.
  OUT="$(PATH="${BIN}:${PATH}" STUB_LOG="${LOG}" STUB_APP_ID="${APP_ID}" \
    STUB_PROJECT="${PROJECT}" KATAGLYPHIS_FLATPAK_WORKDIR="${FLATPAK_WORK}" \
    STUB_DEFAULT_ARCH=x86_64 STUB_USER_REMOTE=1 STUB_SYSTEM_REMOTE=1 \
    STUB_USER_REMOTE_ADD_RC=0 STUB_USER_HAS_REF=1 STUB_SYSTEM_HAS_REF=1 \
    STUB_USER_INSTALL_RC=0 STUB_SYSTEM_INSTALL_RC=0 \
    STUB_FB_RC=0 STUB_OSTREE_EMPTY=0 STUB_BUNDLE_RC=0 STUB_EMPTY_BUNDLE=0 \
    STUB_CMAKE_RC=0 STUB_CMAKE_NO_BIN=0 \
    env "${env_pairs[@]+"${env_pairs[@]}"}" \
    bash -c "$(t_stubbed_script "${LIB}" "$@")" 2>&1)"
  rc=$?
}

# ── app_packaging_require_flatpak_tools ──────────────────────────────────────

# _require <tool>...: exactly these tools resolvable; PATH narrows after sourcing, so host tools cannot leak in.
_require() {
  local dir _t
  dir="$(mktemp -d "${_work}/req.XXXXXX")"
  for _t in "$@"; do
    printf '#!/usr/bin/env bash
exit 0
' > "${dir}/${_t}"
    chmod +x "${dir}/${_t}"
  done
  OUT="$(bash -c "$(printf 'set -uo pipefail
source %q
PATH=%q
app_packaging_require_flatpak_tools
'     "${LIB}" "${dir}")" 2>&1)"
  rc=$?
}

t_case "require_flatpak_tools: all three tools present is a pass"
_require flatpak flatpak-builder ostree
t_assert_eq "0" "${rc}" "output was: ${OUT}"

t_case "require_flatpak_tools: OSTREE is required, and the message says what for"
# Debian's and Ubuntu's flatpak depends on libostree, not the ostree CLI the verdict needs.
_require flatpak flatpak-builder
t_assert_eq "1" "${rc}" "a packaging run whose verdict cannot be asked is not a packaging run"
t_assert_contains "${OUT}" "ostree not found"
t_assert_contains "${OUT}" "is the verdict that the export committed the app"

t_case "require_flatpak_tools: every missing tool names why packaging needs it"
_require ostree
t_assert_eq "1" "${rc}"
t_assert_contains "${OUT}" "flatpak not found"
t_assert_contains "${OUT}" "build-bundle"
t_assert_contains "${OUT}" "flatpak-builder not found"
t_assert_contains "${OUT}" "exports it to the repo"

t_case "require_flatpak_tools: ALL of them are reported, not just the first"
# One apt-get installs all three, so report every missing one at once.
_require
t_assert_eq "3" "$(printf '%s
' "${OUT}" | grep -c 'not found')"

# ── setup_dependencies_for_container (CON2): the image installs refs system-wide, so probe both scopes ──
_setup_deps() {
  _call "$@" -- eval 'app_packaging_ensure_appimagetool_via_antfrastructure() { :; }; app_packaging_setup_dependencies_for_container x64'
}

t_case "setup_dependencies: a SYSTEM-installed ref is not pulled again as a per-user copy"
_setup_deps STUB_SYSTEM_HAS_REF=0
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_eq "" "$(grep -F -- '--user install' "${LOG}" || true)" \
  "the refs the image already ships must not be fetched a second time"
t_assert_contains "${OUT}" "already installed"

t_case "setup_dependencies: a missing ref is still installed per-user"
_setup_deps
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "$(cat "${LOG}")" \
  "--user install -y --arch=x86_64 flathub org.freedesktop.Platform/x86_64/26.08"
t_assert_contains "$(cat "${LOG}")" \
  "--user install -y --arch=x86_64 flathub org.freedesktop.Sdk/x86_64/26.08"

t_case "setup_dependencies: a known remote in EITHER scope skips remote-add"
_setup_deps STUB_SYSTEM_REMOTE=0
t_assert_eq "" "$(grep -F -- 'remote-add' "${LOG}" || true)" \
  "a system remote with the refs present makes the user remote pointless"

t_case "setup_dependencies: a failing per-user install is FATAL, not swallowed"
_setup_deps STUB_USER_INSTALL_RC=1
t_assert_eq "1" "${rc}" "a missing runtime makes flatpak-builder fail much later with a manifest message"

# ── app_packaging_flatpak_finish_args_block (CON6) ───────────────────────────
t_case "finish_args_block: the four generated args are always present"
_call -- app_packaging_flatpak_finish_args_block
t_assert_contains "${OUT}" "  - --share=network"
t_assert_contains "${OUT}" "  - --socket=wayland"
t_assert_contains "${OUT}" "  - --socket=fallback-x11"
t_assert_contains "${OUT}" "  - --device=dri"

t_case "finish_args_block: the knob APPENDS, it never replaces"
_call KATAGLYPHIS_FLATPAK_FINISH_ARGS=--device=all -- app_packaging_flatpak_finish_args_block
t_assert_contains "${OUT}" "  - --device=dri" "the generated args must survive the knob"
t_assert_contains "${OUT}" "  - --device=all"
t_assert_eq "5" "$(printf '%s\n' "${OUT}" | grep -c '^  - ')" "one line per arg, no duplicates"

t_case "finish_args_block: a multi-arg knob adds one YAML line each"
_call "KATAGLYPHIS_FLATPAK_FINISH_ARGS=--device=all --filesystem=home" -- app_packaging_flatpak_finish_args_block
t_assert_contains "${OUT}" "  - --filesystem=home"
t_assert_eq "6" "$(printf '%s\n' "${OUT}" | grep -c '^  - ')"

t_case "package_linux_bundle_flatpak: the manifest is emitted with the appendable block"
t_assert_contains "$(t_fn_src "${LIB}" app_packaging_package_linux_bundle_flatpak)" \
  '$(app_packaging_flatpak_finish_args_block)' \
  "the hook must reach the generated manifest, not just exist beside it"

# ── app_packaging_ensure_flatpak_runtime ─────────────────────────────────────

t_case "ensure_flatpak_runtime: installs runtime AND sdk when neither is present"
_call -- app_packaging_ensure_flatpak_runtime "" org.freedesktop.Platform org.freedesktop.Sdk 26.08
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "$(cat "${LOG}")" "--user install -y --noninteractive flathub org.freedesktop.Platform/x86_64/26.08"
t_assert_contains "$(cat "${LOG}")" "--user install -y --noninteractive flathub org.freedesktop.Sdk/x86_64/26.08"

t_case "ensure_flatpak_runtime: a ref that is already there is NOT reinstalled"
# A user install of a ref present system-wide is a second 1-2 GB copy, not a no-op.
_call STUB_USER_HAS_REF=0 -- app_packaging_ensure_flatpak_runtime
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_eq "" "$(grep -F -- '--user install' "${LOG}" || true)"
t_assert_contains "${OUT}" "already installed"

t_case "ensure_flatpak_runtime: a SYSTEM-installed ref also counts as present"
_call STUB_SYSTEM_HAS_REF=0 -- app_packaging_ensure_flatpak_runtime
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_eq "" "$(grep -F -- 'install' "${LOG}" || true)"

t_case "ensure_flatpak_runtime: a failing --user install falls back to --system"
_call STUB_USER_INSTALL_RC=1 -- app_packaging_ensure_flatpak_runtime
t_assert_eq "0" "${rc}" "an unprivileged user cannot always write either installation; output was: ${OUT}"
t_assert_contains "$(cat "${LOG}")" "--system install -y --noninteractive flathub org.freedesktop.Platform"

t_case "ensure_flatpak_runtime: both installs failing is FATAL, not a warning"
_call STUB_USER_INSTALL_RC=1 STUB_SYSTEM_INSTALL_RC=1 -- app_packaging_ensure_flatpak_runtime
t_assert_eq "1" "${rc}" "a missing runtime makes flatpak-builder fail much later, with a message about the manifest"

t_case "ensure_flatpak_runtime: flathub is added only when neither scope knows it"
_call -- app_packaging_ensure_flatpak_runtime
t_assert_contains "$(cat "${LOG}")" "--user remote-add --if-not-exists flathub"
_call STUB_USER_REMOTE=0 -- app_packaging_ensure_flatpak_runtime
t_assert_eq "" "$(grep -F -- 'remote-add' "${LOG}" || true)"

t_case "ensure_flatpak_runtime: a failing --user remote-add falls back to --system"
_call STUB_USER_REMOTE_ADD_RC=1 -- app_packaging_ensure_flatpak_runtime
t_assert_contains "$(cat "${LOG}")" "--system remote-add --if-not-exists flathub"

t_case "ensure_flatpak_runtime: an explicit arch wins over flatpak --default-arch"
_call STUB_DEFAULT_ARCH=x86_64 -- app_packaging_ensure_flatpak_runtime aarch64
t_assert_contains "$(cat "${LOG}")" "org.freedesktop.Platform/aarch64/"

t_case "ensure_flatpak_runtime: with no explicit arch, flatpak's own default is used"
_call STUB_DEFAULT_ARCH=aarch64 -- app_packaging_ensure_flatpak_runtime
t_assert_contains "$(cat "${LOG}")" "org.freedesktop.Platform/aarch64/"

t_case "ensure_flatpak_runtime: the runtime version defaults to the hub pin"
# FLATPAK_RUNTIME_VERSION is a versions.env pin; a literal would drift from it silently.
_call -- app_packaging_ensure_flatpak_runtime
t_assert_contains "$(cat "${LOG}")" "org.freedesktop.Platform/x86_64/${FLATPAK_RUNTIME_VERSION:-26.08}"

# ── app_packaging_package_cmake_install_flatpak ──────────────────────────────

_bdir="${_work}/build-release"
_odir="${_work}/out"
mkdir -p "${_bdir}"

t_case "package_cmake_install_flatpak: the happy path produces a bundle and says so"
_call -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v1.2.3"
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "${OUT}" "Created: ${_odir}/${PROJECT}-v1.2.3-linux.flatpak"
t_assert_ok test -s "${_odir}/${PROJECT}-v1.2.3-linux.flatpak"

t_case "package_cmake_install_flatpak: the payload comes from cmake --install"
t_assert_contains "$(cat "${LOG}")" "cmake --install ${_bdir} --prefix ${FLATPAK_WORK}/cmake-install/source/app"

t_case "package_cmake_install_flatpak: staging is CONTAINER-NATIVE, not under the build or out dir"
# flatpak needs fchmod, which a bind-mounted host drive refuses, and out_dir is often on one.
t_assert_eq "" "$(grep -F -- "--repo=${_bdir}" "${LOG}" || true)"
t_assert_eq "" "$(grep -F -- "--repo=${_odir}" "${LOG}" || true)"
t_assert_contains "$(cat "${LOG}")" "--repo=${FLATPAK_WORK}/cmake-install/repo"
t_assert_eq "" "$(find "${_bdir}" -mindepth 1 2>/dev/null)" \
  "the build directory must come out of the packaging step exactly as it went in"

t_case "package_cmake_install_flatpak: flatpak-builder gets the flags a mounted host needs"
t_assert_contains "$(cat "${LOG}")" "flatpak-builder --disable-rofiles-fuse --force-clean"
t_assert_contains "$(cat "${LOG}")" "--state-dir=${FLATPAK_WORK}/cmake-install/state"

t_case "package_cmake_install_flatpak: build-bundle is given the branch"
t_assert_contains "$(cat "${LOG}")" "build-bundle ${FLATPAK_WORK}/cmake-install/repo ${FLATPAK_WORK}/cmake-install/${PROJECT}-v1.2.3-linux.flatpak ${APP_ID} master"
_call -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v1" '' '' '' stable
t_assert_contains "$(cat "${LOG}")" "${APP_ID} stable"

t_case "package_cmake_install_flatpak: the manifest names the app, runtime, sdk and command"
_call -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v1.2.3" \
  org.freedesktop.Platform org.freedesktop.Sdk 26.08
_manifest="${FLATPAK_WORK}/cmake-install/${APP_ID}.json"
t_assert_ok test -f "${_manifest}"
t_assert_contains "$(cat "${_manifest}")" "\"app-id\": \"${APP_ID}\""
t_assert_contains "$(cat "${_manifest}")" "\"runtime-version\": \"26.08\""
t_assert_contains "$(cat "${_manifest}")" "\"command\": \"${PROJECT}\""
t_assert_contains "$(cat "${_manifest}")" "\"path\": \"${FLATPAK_WORK}/cmake-install/source/app\""

t_case "package_cmake_install_flatpak: the PROJECT-named install files are renamed to the APP ID"
# flatpak resolves by app id; a project-named .desktop is a silently iconless, unlaunchable app.
_stage="${FLATPAK_WORK}/cmake-install/source/app"
t_assert_ok test -f "${_stage}/share/applications/${APP_ID}.desktop"
t_assert_ok test -f "${_stage}/share/icons/hicolor/256x256/apps/${APP_ID}.png"
t_assert_ok test -f "${_stage}/share/metainfo/${APP_ID}.appdata.xml"
t_assert_eq "" "$(find "${_stage}/share" -name "${PROJECT}.*" 2>/dev/null)" \
  "the project-named copies must be MOVED, not duplicated: two .desktop files is an ambiguous install"

t_case "package_cmake_install_flatpak: a non-zero flatpak-builder with a COMMITTED app still ships"
# The export can be complete while `Pruning cache` fails on fchmod; the exit code is never the verdict.
_call STUB_FB_RC=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "${OUT}" "flatpak-builder exited 1"
t_assert_contains "${OUT}" "Created: "

t_case "package_cmake_install_flatpak: a ZERO exit with nothing committed FAILS"
_call STUB_OSTREE_EMPTY=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "1" "${rc}" "the ostree ref is the verdict; a green exit code with an empty repo is the case that made this rule"
t_assert_contains "${OUT}" "is not in "
t_assert_eq "" "$(grep -F 'build-bundle' "${LOG}" || true)"

t_case "package_cmake_install_flatpak: an install with no executable fails, naming the path"
_call STUB_CMAKE_NO_BIN=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "1" "${rc}" "committing an app whose command is missing moves the failure onto a user's machine"
t_assert_contains "${OUT}" "bin/${PROJECT}"
t_assert_eq "" "$(grep -F 'flatpak-builder' "${LOG}" || true)"

t_case "package_cmake_install_flatpak: a failing cmake --install stops the run"
_call STUB_CMAKE_RC=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "1" "${rc}"
t_assert_contains "${OUT}" "cmake --install failed"

t_case "package_cmake_install_flatpak: a bundle file that is EMPTY is not a success"
# build-bundle can exit 0 having written nothing, so success needs app_packaging_assert_artifact.
_call STUB_EMPTY_BUNDLE=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "1" "${rc}"
t_assert_contains "${OUT}" "missing or empty"
t_assert_eq "" "$(printf '%s' "${OUT}" | grep -F 'Created: ' || true)"

t_case "package_cmake_install_flatpak: a failing build-bundle stops the run"
_call STUB_BUNDLE_RC=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "1" "${rc}"

t_summary
