#!/usr/bin/env bash
# No apt ONNX Runtime lands (2026-08-27 pulled libonnxruntime1.23); loader paths reach the chain only.
# NOT covered: a real dpkg/apt/ldconfig -- their output is recorded text here; dlopen by full path.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RT="${TESTS_DIR}/../03-media/runtime"
GATE="${RT}/ort-runtime-gate.sh"
VMR="${RT}/validate-media-runtime.sh"
CONF="${RT}/configure-runtime.sh"
MAP="${RT}/so-package-map.txt"
# Git Bash on a Windows host makes copies for `ln -s` without this; a no-op on Linux.
export MSYS=winsymlinks:nativestrict
# shellcheck source=../03-media/runtime/ort-runtime-gate.sh
source "${GATE}"

_fx="$(mktemp -d)"
trap 'rm -rf "${_fx}"' EXIT

t_case "every ORT package name is recognised, and only those"
for _p in libonnxruntime1.23 libonnxruntime1.23:arm64 libonnxruntime-dev libonnxruntime-providers \
    python3-onnxruntime onnxruntime-tools; do
  t_assert_ok ort_is_distro_package "${_p}"
done
for _p in libonnx1 python3-onnx libopencv-dnn410 libgstreamer-plugins-bad1.0-0; do
  t_assert_fails ort_is_distro_package "${_p}"
done

t_case "the resolver denies every ORT soname in code, the unversioned and provider ones too"
for _so in libonnxruntime.so.1 libonnxruntime.so libonnxruntime_providers_shared.so libonnxruntime-genai.so; do
  t_assert_ok ort_is_denied_soname "${_so}"
done
t_assert_fails ort_is_denied_soname libavcodec.so.62

t_case "resolve_package_for_so returns DENIED for ORT even with an EMPTY map"
# The map is WARN-only when missing; the 2026-08-27 path was the apt-cache prefix guess behind it.
_rfn="$(t_fn_src "${VMR}" resolve_package_for_so)" || exit 1
_resolve() {
  bash -c "source '${GATE}'; declare -A KNOWN_SO_PACKAGES=(); declare -a KNOWN_SO_GLOBS=()
    SO_PACKAGE_DENY=source-built
    dpkg-query() { return 1; }; apt-cache() { echo 'libonnxruntime1.23 - ONNX Runtime'; }
    ${_rfn}
    resolve_package_for_so '$1'; echo \"RC=\$?\"" 2>&1
}
t_assert_contains "$(_resolve libonnxruntime.so.1)" "RC=2"
t_assert_contains "$(_resolve libonnxruntime.so)" "RC=2"
t_assert_contains "$(_resolve libonnxruntime_providers_shared.so)" "RC=2"
t_assert_contains "$(_resolve libfoo.so.3)" "RC=0" "a non-ORT miss still reaches apt, so the stub is live"

t_case "the map's deny row covers the unversioned soname too"
t_assert_ok grep -qxF -e $'libonnxruntime.so*\tsource-built' "${MAP}"

t_case "dpkg: an installed ORT package is a finding, a removed one is not"
_dpkg="$(printf '%s\t%s\n' 'install ok installed' libonnxruntime1.23 'install ok unpacked' 'python3-onnxruntime' \
  'deinstall ok config-files' libonnxruntime1.21 'install ok installed' libopencv-core410)"
_out="$(ort_dpkg_findings "${_dpkg}")"
t_assert_contains "${_out}" "APT libonnxruntime1.23 is installed"
t_assert_contains "${_out}" "APT python3-onnxruntime is installed"
t_assert_eq "2" "$(grep -c . <<< "${_out}")" "config-files and non-ORT packages do not count"
t_assert_eq "" "$(ort_dpkg_findings "$(printf '%s\t%s\n' 'install ok installed' libc6)")"

t_case "apt plan: an ORT package anywhere in the simulated install is a finding"
_plan="$(printf '%s\n' 'Inst libgstreamer-plugins-bad1.0-0:arm64 (1.28.2-1 Ubuntu [arm64])' \
  'Inst libonnxruntime1.23:arm64 (1.23.2-1 Ubuntu [arm64])' 'Conf libonnxruntime1.23:arm64 (1.23.2-1)')"
t_assert_contains "$(ort_apt_plan_findings "${_plan}")" "APT-PLAN libonnxruntime1.23:arm64 would be installed"
t_assert_eq "1" "$(ort_apt_plan_findings "${_plan}" | grep -c .)" "Conf lines are not installs"

t_case "the two gates FAIL on those findings and pass on a clean system"
_gate() {
  bash -c "source '${GATE}'
    apt-get() { printf '%s\n' \"\${APT_OUT}\"; }
    dpkg-query() { printf '%s\n' \"\${DPKG_OUT}\"; }
    $1; echo \"RC=\$?\"" 2>&1
}
t_assert_contains "$(APT_OUT="${_plan}" DPKG_OUT="" _gate 'ort_apt_plan_gate libfoo1')" "RC=1"
t_assert_contains "$(APT_OUT='Inst libfoo1 (1 Ubuntu)' DPKG_OUT="" _gate 'ort_apt_plan_gate libfoo1')" "RC=0"
_xplan() {
  bash -c "source '${GATE}'; cross_resolve_target_package() { printf '%s:arm64' \"\$1\"; }
    apt-get() { printf 'Inst %s (1 Ubuntu)\n' \"\$4\"; }; ort_apt_plan_gate '$1'; echo \"RC=\$?\"" 2>&1
}
t_assert_contains "$(_xplan libonnxruntime1.23)" "APT-PLAN libonnxruntime1.23:arm64 would be installed"
t_assert_contains "$(_xplan libfoo1)" "RC=0" "the cross-resolved names are what apt simulates"
t_assert_contains "$(APT_OUT="" DPKG_OUT="${_dpkg}" _gate ort_dpkg_gate)" "RC=1"
t_assert_contains "$(APT_OUT="" DPKG_OUT="" _gate ort_dpkg_gate)" "RC=0"

t_case "validate-media-runtime: the plan gate runs before the install, the dpkg gate before exit"
_vmr="$(cat "${VMR}")"
_plan_at="$(grep -n -e 'ort_apt_plan_gate "${UNIQ_PKGS\[@\]}" || exit 1' "${VMR}" | cut -d: -f1)"
_inst_at="$(grep -n -e 'install_target_packages "${UNIQ_PKGS\[@\]}"' "${VMR}" | head -1 | cut -d: -f1)"
t_assert_ok test -n "${_plan_at}"
t_assert_ok test "${_plan_at:-999999}" -lt "${_inst_at:-0}"
t_assert_contains "${_vmr}" "ort_dpkg_gate || exit 1"
t_assert_contains "${_vmr}" 'source "${SCRIPT_DIR}/ort-runtime-gate.sh"'
t_assert_contains "${_vmr}" 'ort_is_denied_soname "${so_name}" && return 2'

# A loader view of an image: the chain, dnn's forwarding links, and the distro dir.
_chain="${_fx}/usr/local/lib/onnxruntime-cpu/lib"
_ocv="${_fx}/opt/opencv5/lib"
_distro="${_fx}/usr/lib/x86_64-linux-gnu"
mkdir -p "${_chain}" "${_ocv}" "${_distro}" "${_fx}/usr/local/lib/onnxruntime-gpu/lib"
printf 'chain' > "${_chain}/libonnxruntime.so.1.30.0"
ln -s libonnxruntime.so.1.30.0 "${_chain}/libonnxruntime.so.1"
printf 'provider' > "${_chain}/libonnxruntime_providers_shared.so"
ln -s "${_chain}/libonnxruntime.so.1" "${_ocv}/libonnxruntime.so.1"
_chains="${_chain}:${_fx}/usr/local/lib/onnxruntime-gpu/lib"
_loader() { ort_loader_findings "${_chains}" "${_ocv}" "${_distro}" "${_chain}" "${_fx}/nothere"; }

t_case "loader: the chain plus forwarding links into it is clean"
t_assert_eq "" "$(_loader)"

t_case "loader: a real copy, a distro soname, a stray provider and a dead link are each caught"
cp "${_chain}/libonnxruntime.so.1.30.0" "${_ocv}/libonnxruntime.so.1.30.0"
printf 'ubuntu' > "${_distro}/libonnxruntime.so.1.23"
printf 'x' > "${_distro}/libonnxruntime_providers_cuda.so"
ln -s "${_fx}/gone/libonnxruntime.so" "${_ocv}/libonnxruntime.so"
_out="$(_loader)"
t_assert_contains "${_out}" "FOREIGN ${_ocv}/libonnxruntime.so.1.30.0"
t_assert_contains "${_out}" "FOREIGN ${_distro}/libonnxruntime.so.1.23"
t_assert_contains "${_out}" "FOREIGN ${_distro}/libonnxruntime_providers_cuda.so"
t_assert_contains "${_out}" "DANGLING ${_ocv}/libonnxruntime.so"
rm -f "${_ocv}/libonnxruntime.so.1.30.0" "${_distro}"/libonnxruntime* "${_ocv}/libonnxruntime.so"

t_case "loader: a chain dir with no real ORT is NONE, never a vacuous pass"
t_assert_contains "$(ort_loader_findings "${_fx}/empty" "${_ocv}")" "NONE no real libonnxruntime.so.*"

t_case "ort_runtime_gate fails on a dpkg finding and on a loader finding, passes on neither"
_rtg() {
  bash -c "source '${GATE}'; ort_dpkg_gate() { return $1; }; ort_conf_dirs() { :; }
    ort_loader_findings() { printf '%s' '$2'; }; ort_runtime_gate x; echo \"RC=\$?\"" 2>&1
}
t_assert_contains "$(_rtg 0 '')" "RC=0"
t_assert_contains "$(_rtg 1 '')" "RC=1"
t_assert_contains "$(_rtg 0 'FOREIGN /opt/opencv5/lib/libonnxruntime.so.1.30.0')" "RC=1"

t_case "ld.so.conf.d: directories are read off every conf, comments and includes skipped"
mkdir -p "${_fx}/conf.d"
printf '%s\n' "# chain" "/usr/local/lib/onnxruntime-cpu/lib" "/usr/local/lib/onnxruntime-genai/lib  # genai" \
  > "${_fx}/conf.d/000-onnxruntime.conf"
printf '%s\n' "include /etc/ld.so.conf.d/*.conf" "/opt/opencv5/lib" > "${_fx}/conf.d/000-opencv.conf"
t_assert_eq "$(printf '%s\n' /usr/local/lib/onnxruntime-cpu/lib /usr/local/lib/onnxruntime-genai/lib /opt/opencv5/lib)" \
  "$(ort_conf_dirs "${_fx}/conf.d")"

t_case "configure-runtime: the chain conf is 000- (AGENTS.md priority 5) and the gate runs after ldconfig"
_conf="$(cat "${CONF}")"
t_assert_contains "${_conf}" 'write_conf /etc/ld.so.conf.d/000-onnxruntime.conf "/usr/local/lib/onnxruntime-cpu/lib"'
t_assert_contains "${_conf}" "rm -f /etc/ld.so.conf.d/onnxruntime.conf"
t_assert_eq "0" "$(grep -c -e 'write_conf /etc/ld.so.conf.d/onnxruntime.conf' "${CONF}" || true)"
t_assert_eq "000-onnxruntime.conf" "$(printf '%s\n' 000-opencv.conf 000-onnxruntime.conf | LC_ALL=C sort | head -1)" \
  "the chain dir must be read before /opt/opencv5/lib"
t_assert_contains "${_conf}" "$(printf '%s\n\n%s' ldconfig '# Owner rule 2026-09-23')"
t_assert_contains "${_conf}" 'ort_runtime_gate "/usr/local/lib/onnxruntime-cpu/lib:/usr/local/lib/onnxruntime-gpu/lib"'

t_summary
