#!/usr/bin/env bash
# app_packaging_ensure_flatpak_runtime and
# app_packaging_package_cmake_install_flatpak (lib/app-packaging.sh), both of
# which were local forks in AccelerANTgine until 2026-09-15.
#
# What is pinned here is what a green run cannot show: the three conventions in
# app-packaging.sh's header -- container-native staging, ostree and not the exit
# code as the verdict, no success line without assert_artifact -- and the
# user-first/system-fallback install. Stubs for flatpak/flatpak-builder/ostree/
# cmake record every invocation and can be told to fail a chosen one.
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

# `cmake --install <dir> --prefix <p>` lays down the tree a real CMake install
# would: the binary plus the three PROJECT-named files the packager has to
# rename. STUB_CMAKE_NO_BIN=1 reproduces an install that succeeded with nothing
# in bin/ (a component filter, or a target that was never built).
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

chmod +x "${BIN}/flatpak" "${BIN}/flatpak-builder" "${BIN}/ostree" "${BIN}/cmake"

APP_ID="org.kataglyphis.accelerantgine"
PROJECT="KataglyphisCppProject"

OUT=""; rc=0; LOG=""; FLATPAK_WORK=""
# _call <env-assignments...> -- <function> <args...>
# Runs one library function in its own shell with the stubs first on PATH.
_call() {
  local -a env_pairs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do env_pairs+=("$1"); shift; done
  shift
  LOG="$(mktemp "${_work}/log.XXXXXX")"
  FLATPAK_WORK="$(mktemp -d "${_work}/fpwork.XXXXXX")"
  # Every fixture switch is spelled here with its default, and `env` below
  # overrides the one or two a case is about. Spelled rather than left to the
  # stubs' own ${X:-default}: a switch only a stub mentions has no owner, and a
  # test fixture's switch is not an operator switch -- it must not be parked in
  # lint-env-knobs.allow to quieten the registry gate.
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

# ── app_packaging_ensure_flatpak_runtime ─────────────────────────────────────

t_case "ensure_flatpak_runtime: installs runtime AND sdk when neither is present"
_call -- app_packaging_ensure_flatpak_runtime "" org.freedesktop.Platform org.freedesktop.Sdk 24.08
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "$(cat "${LOG}")" "--user install -y --noninteractive flathub org.freedesktop.Platform/x86_64/24.08"
t_assert_contains "$(cat "${LOG}")" "--user install -y --noninteractive flathub org.freedesktop.Sdk/x86_64/24.08"

t_case "ensure_flatpak_runtime: a ref that is already there is NOT reinstalled"
# 1-2 GB per ref, and a user install of a ref the machine already has
# system-wide is a second copy, not a no-op.
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
# FLATPAK_RUNTIME_VERSION is a versions.env pin; a literal here would drift from
# it silently, which is the defect the consumer's own header records.
_call -- app_packaging_ensure_flatpak_runtime
t_assert_contains "$(cat "${LOG}")" "org.freedesktop.Platform/x86_64/${FLATPAK_RUNTIME_VERSION:-24.08}"

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
# Everything flatpak touches needs fchmod, which a bind-mounted host drive
# refuses. out_dir is routinely the build directory on a mounted workspace, so
# staging there is the failure this convention exists to prevent.
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
  org.freedesktop.Platform org.freedesktop.Sdk 24.08
_manifest="${FLATPAK_WORK}/cmake-install/${APP_ID}.json"
t_assert_ok test -f "${_manifest}"
t_assert_contains "$(cat "${_manifest}")" "\"app-id\": \"${APP_ID}\""
t_assert_contains "$(cat "${_manifest}")" "\"runtime-version\": \"24.08\""
t_assert_contains "$(cat "${_manifest}")" "\"command\": \"${PROJECT}\""
t_assert_contains "$(cat "${_manifest}")" "\"path\": \"${FLATPAK_WORK}/cmake-install/source/app\""

t_case "package_cmake_install_flatpak: the PROJECT-named install files are renamed to the APP ID"
# CMake install rules name after the project; flatpak resolves by app id, and a
# .desktop under the wrong name is a silently iconless, unlaunchable app.
_stage="${FLATPAK_WORK}/cmake-install/source/app"
t_assert_ok test -f "${_stage}/share/applications/${APP_ID}.desktop"
t_assert_ok test -f "${_stage}/share/icons/hicolor/256x256/apps/${APP_ID}.png"
t_assert_ok test -f "${_stage}/share/metainfo/${APP_ID}.appdata.xml"
t_assert_eq "" "$(find "${_stage}/share" -name "${PROJECT}.*" 2>/dev/null)" \
  "the project-named copies must be MOVED, not duplicated: two .desktop files is an ambiguous install"

t_case "package_cmake_install_flatpak: a non-zero flatpak-builder with a COMMITTED app still ships"
# The export can be complete while `Pruning cache` fails with fchmod: Operation
# not permitted. The exit code is reported, never used as the verdict.
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
# Convention 3: nothing announces success without app_packaging_assert_artifact.
# build-bundle can exit 0 having written nothing.
_call STUB_EMPTY_BUNDLE=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "1" "${rc}"
t_assert_contains "${OUT}" "missing or empty"
t_assert_eq "" "$(printf '%s' "${OUT}" | grep -F 'Created: ' || true)"

t_case "package_cmake_install_flatpak: a failing build-bundle stops the run"
_call STUB_BUNDLE_RC=1 -- app_packaging_package_cmake_install_flatpak "${_bdir}" "${_odir}" "${APP_ID}" "${PROJECT}" "v9"
t_assert_eq "1" "${rc}"

t_summary
