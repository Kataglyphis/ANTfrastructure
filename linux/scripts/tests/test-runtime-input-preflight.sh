#!/usr/bin/env bash
# The runtime lane's input preflight with nerdctl, apt and the downloads stubbed; a real apt or registry is not exercised: docs/linux-cross-builds.md#the-runtime-lane-input-preflight
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
LIB="${SCRIPTS}/lib-runtime-preflight.sh"
PLAN="${SCRIPTS}/06-packaging/package-apt-plan.sh"
BRM="${SCRIPTS}/build-runtime-manifest.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# Records each run's argv; FAIL_ARCH=<arch> prints apt's skew line and fails that arch.
cat > "${_work}/nerdctl" <<'EOF'
#!/usr/bin/env bash
arch=""; prev=""
for a in "$@"; do [ "${prev}" = --platform ] && arch="${a#linux/}"; prev="${a}"; done
printf '%s\n' "$@" > "${W}/run.${arch}"
if [ "${arch}" = "${FAIL_ARCH:-none}" ]; then
  echo " xvfb : Depends: xserver-common (>= 2:21.1.22-1ubuntu1.3) but it is not going to be installed" >&2
  exit 1
fi
echo "OK: apt plan: 1 package(s) resolve: xvfb"
EOF
chmod +x "${_work}/nerdctl"

# A lane process: the real host libraries, the stubs, then $1; prints its output and RC=<rc>.
_lane() {
  rm -rf "${_work}/w"; mkdir -p "${_work}/w"
  cat > "${_work}/lane.sh" <<EOF
set -euo pipefail
REPO_ROOT=$(printf '%q' "$(cd "${SCRIPTS}/../.." && pwd)")
source $(printf '%q' "${SCRIPTS}/01-core/artifact-common.sh") >/dev/null 2>&1
source $(printf '%q' "${LIB}")
log() { printf 'LOG %s\n' "\$*"; }
download_verified_file() {
  printf '%s\n' "\$1" >> "\${W}/downloads"
  [ "\$1" != "\${BAD_URL:-none}" ]
}
rc=0
$1 || rc=\$?
echo "RC=\${rc}"
EOF
  W="${_work}/w" TMPDIR="${_work}/w" NERDCTL_BIN="${_work}/nerdctl" \
    TARGET_ARCHES="${TARGET_ARCHES:-amd64,arm64,riscv64}" \
    UBUNTU_VERSION=26.04 UBUNTU_DIGEST=sha256:feed PYTHON_VERSION=3.15.0 GCC_VERSION=16.2.0 \
    LLVM_RELEASE=23.1.3 JDK_PACKAGE=openjdk-21-jdk-headless \
    RUSTUP_INIT_SHA256="${RUSTUP_INIT_SHA256-aaaa}" UV_INSTALL_SH_SHA256="${UV_INSTALL_SH_SHA256-bbbb}" \
    bash "${_work}/lane.sh" 2>&1
}

t_case "on by default; 0 is the documented way back; a typo stops the lane with rc 2"
t_assert_contains "$(_lane runtime_preflight_mode)" "onRC=0"
t_assert_contains "$(RUNTIME_INPUT_PREFLIGHT=0 _lane runtime_preflight_mode)" "offRC=0"
_out="$(RUNTIME_INPUT_PREFLIGHT=yes _lane runtime_input_preflight)"
t_assert_contains "${_out}" "RUNTIME_INPUT_PREFLIGHT=yes: expected 1"
t_assert_contains "${_out}" "RC=2"
t_assert_ok test ! -e "${_work}/w/downloads"

t_case "every arch's apt set and every pinned installer pass: rc 0, each arch run under its own platform"
_out="$(_lane runtime_input_preflight)"
t_assert_contains "${_out}" "RC=0"
t_assert_contains "${_out}" "[runtime-preflight riscv64] OK: apt plan"
for _a in amd64 arm64 riscv64; do
  t_assert_grep "${_work}/w/run.${_a}" "^linux/${_a}$"
done
t_assert_eq "https://sh.rustup.rs" "$(cat "${_work}/w/downloads")" "uv's installer is not checked: the package stage never runs it"

t_case "the container is the base's pinned parent, with the package stage's scripts and pins"
_run="$(cat "${_work}/w/run.arm64")"
t_assert_contains "${_run}" "ubuntu:26.04@sha256:feed"
t_assert_contains "${_run}" "${SCRIPTS}/06-packaging:/opt/scripts/packaging:ro"
t_assert_contains "${_run}" "${SCRIPTS}/01-core:/opt/scripts/core:ro"
t_assert_contains "${_run}" "PYTHON_MAJOR_MINOR=3.15"
t_assert_contains "${_run}" "JDK_PACKAGE=openjdk-21-jdk-headless"
t_assert_contains "${_run}" "USE_FAST_UBUNTU_MIRROR=false"
t_assert_eq "bash /opt/scripts/packaging/package-apt-plan.sh" "$(tail -n 2 "${_work}/w/run.arm64" | tr '\n' ' ' | sed 's/ $//')"
_out="$(BASE_PARENT_IMAGE=example/base:1 _lane runtime_input_preflight)"
t_assert_grep "${_work}/w/run.amd64" "^example/base:1$"

t_case "an apt conflict on one arch refuses the lane and prints apt's line; the other arches still report"
_out="$(FAIL_ARCH=riscv64 _lane runtime_input_preflight)"
t_assert_contains "${_out}" "RC=1"
t_assert_contains "${_out}" "[runtime-preflight riscv64]  xvfb : Depends: xserver-common"
t_assert_contains "${_out}" "[runtime-preflight arm64] OK: apt plan"
t_assert_contains "${_out}" "refused"

t_case "a rotated installer refuses the lane and names its pin, even when every apt plan resolves"
_out="$(BAD_URL=https://sh.rustup.rs _lane runtime_input_preflight)"
t_assert_contains "${_out}" "RC=1"
t_assert_contains "${_out}" "https://sh.rustup.rs no longer matches RUSTUP_INIT_SHA256"

t_case "an empty pin is the documented skip: not downloaded, said out loud"
# After the libraries load: versions.env fills a pin the environment leaves empty.
_out="$(_lane "RUSTUP_INIT_SHA256='' runtime_preflight_installers")"
t_assert_contains "${_out}" "RC=0"
t_assert_contains "${_out}" "RUSTUP_INIT_SHA256 is empty"
t_assert_eq "" "$(cat "${_work}/w/downloads" 2>/dev/null)"

t_case "off and dry-run touch neither nerdctl nor the network"
_out="$(RUNTIME_INPUT_PREFLIGHT=0 _lane runtime_input_preflight)"
t_assert_contains "${_out}" "RC=0"
t_assert_contains "${_out}" "skipped"
_out="$(DRY_RUN=1 _lane runtime_input_preflight)"
t_assert_contains "${_out}" "RC=0"
t_assert_contains "${_out}" "[DRY RUN] [runtime-preflight]"
t_assert_ok test ! -e "${_work}/w/downloads"
t_assert_ok test ! -e "${_work}/w/run.amd64"

# In-container half: apt-get and select_dev_packages stubbed, the real plan functions.
_plan() {
  cat > "${_work}/plan.sh" <<EOF
set -euo pipefail
source $(printf '%q' "${PLAN}")
apt-get() {
  printf '%s\n' "\$*" >> "${_work}/apt"
  case "\$1" in update) return 0 ;; esac
  printf '%s\n' "\${APT_OUT:-}"
  return "\${APT_RC:-0}"
}
install() { :; }
select_dev_packages() { local -n _o=\$1; _o=(jq xvfb); }
rc=0
$1 || rc=\$?
echo "RC=\${rc}"
EOF
  : > "${_work}/apt"
  PYTHON_MAJOR_MINOR=3.15 GCC_VERSION=16.2.0 bash "${_work}/plan.sh" 2>&1
}

t_case "the plan updates, then simulates exactly select_dev_packages' set without recommends"
_out="$(_plan apt_plan_main)"
t_assert_contains "${_out}" "OK: apt plan: 2 package(s) resolve: jq xvfb"
t_assert_contains "${_out}" "RC=0"
t_assert_eq "update
install --simulate --no-install-recommends jq xvfb" "$(cat "${_work}/apt")"

t_case "a simulate failure prints apt's conflict lines and fails"
_out="$(APT_RC=100 APT_OUT=$'Reading package lists...\n xvfb : Depends: xserver-common (>= 2:21.1.22) but it is not going to be installed\nE: Unable to correct problems, you have held broken packages.' _plan apt_plan_main)"
t_assert_contains "${_out}" "RC=1"
t_assert_contains "${_out}" " xvfb : Depends: xserver-common"
t_assert_contains "${_out}" "E: Unable to correct problems"
printf '%s\n' "${_out}" > "${_work}/plan.out"
t_assert_no_grep "${_work}/plan.out" "Reading package lists"

t_case "a failure apt explains without a conflict line still shows apt's own tail"
_out="$(APT_RC=100 APT_OUT='Temporary failure resolving ports.ubuntu.com' _plan apt_plan_main)"
t_assert_contains "${_out}" "RC=1"
t_assert_contains "${_out}" "Temporary failure resolving ports.ubuntu.com"

t_case "no GCC_VERSION, no plan"
_out="$(PYTHON_MAJOR_MINOR=3.15 GCC_VERSION='' bash -c "source $(printf '%q' "${PLAN}"); apt_plan_main" 2>&1)"
t_assert_contains "${_out}" "GCC_VERSION is required"

t_case "setup-package-image.sh only defines when sourced, so the plan can borrow select_dev_packages"
t_assert_contains "$(tail -n 3 "${SCRIPTS}/06-packaging/setup-package-image.sh")" 'if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi'

t_case "the manifest lane runs the preflight after binfmt and before the first push or build, and stops on its failure"
_fn="$(t_fn_src "${BRM}" _manifest_build_and_smoke)" || exit 1
_build() (
  set +e
  eval "${_fn}"
  ensure_foreign_binfmt() { echo binfmt; }
  runtime_input_preflight() { echo preflight; return "${PREFLIGHT_RC:-0}"; }
  runtime_push_queue_start() { echo queue; }
  run_parallel_arch_loop() { echo build; }
  runtime_reuse_pull() { :; }
  arch_loop_flag_prefix() { :; }
  arch_list_to_words() { :; }
  runtime_push_queue_finish() { :; }
  # shellcheck disable=SC2034 # The extracted production function reads these fixture globals.
  RUNTIME_IMAGE_SMOKE=0 TARGET_ARCHES=amd64 MAX_PARALLEL_ARCHS=1
  _manifest_build_and_smoke; echo "rc=$?"
)
t_assert_eq "binfmt preflight queue build rc=0" "$(_build | tr '\n' ' ' | sed 's/ $//')"
t_assert_eq "binfmt preflight rc=1" "$(PREFLIGHT_RC=1 _build | tr '\n' ' ' | sed 's/ $//')"
t_assert_contains "$(cat "${SCRIPTS}/lib-orchestrator.sh")" 'source "${_LIB_ORCHESTRATOR_DIR}/lib-runtime-preflight.sh"'

t_summary
