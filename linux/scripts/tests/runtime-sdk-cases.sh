#!/usr/bin/env bash
# Runs in the runtime-image suite's shared fixture shell.

# Vulkan loader: Ubuntu's multiarch libvulkan is in every image, so which one answered matters
_vk_gate() {
  VK_OUT="$1" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "%s\n" "${VK_OUT}"; }
    '"$(sed -n '/^_VK_WSI_REQUIRED=/p' "${SMOKE}")"'
    '"$(_extract _vk_wsi_verdict)"'
    '"$(_extract _vk_loaded_path)"'
    '"$(_extract check_vulkan_loader)"'
    check_vulkan_loader img arm64'
}

# Probe output: WSI_OK is what the CON41 fix lists on every arch, WSI_NONE what arm64/riscv64 listed before it.
_VK_EXT_WSI_OK='VKEXT VK_KHR_display VK_KHR_get_surface_capabilities2 VK_KHR_surface VK_KHR_wayland_surface VK_KHR_xcb_surface VK_KHR_xlib_surface VK_EXT_acquire_xlib_display VK_EXT_headless_surface'
_VK_EXT_WSI_NONE='VKEXT VK_KHR_display VK_KHR_get_surface_capabilities2 VK_KHR_surface VK_EXT_acquire_drm_display VK_EXT_headless_surface'

# _vk_shipped <VKEXT line>: the gate on a loader resolved inside the shipped /opt/vulkan prefix.
_vk_shipped() {
  _vk_gate "VKLIB /opt/vulkan/1.4.357.0/aarch64/lib/libvulkan.so.1.4.357
VKOK 1.4.357
$1"
}

t_case "a loader resolved inside /opt/vulkan is the pass"
_VK="$(_vk_shipped "${_VK_EXT_WSI_OK}")"
t_assert_contains "${_VK}" "libvulkan.so.1 loads from /opt/vulkan/1.4.357.0/aarch64/lib/libvulkan.so.1.4.357" \
  "the pass line must name the path it read, not just say OK"
t_assert_eq "" "$(printf '%s\n' "${_VK}" | grep -e '^FAIL')" "a shipped-prefix loader is not a failure"

t_case "the distro loader answering instead of the shipped prefix FAILS"
_VK="$(_vk_gate "VKLIB /usr/lib/aarch64-linux-gnu/libvulkan.so.1.4.341
VKOK 1.4.341
${_VK_EXT_WSI_OK}")"
t_assert_contains "${_VK}" "FAIL libvulkan.so.1 loaded from /usr/lib/aarch64-linux-gnu/libvulkan.so.1.4.341" \
  "a prune that took the prefix the image runs would otherwise pass on Ubuntu's loader"

t_case "a load that names no path is a warning, not a verdict either way"
_VK="$(_vk_gate "VKOK 1.4.357
${_VK_EXT_WSI_OK}")"
t_assert_contains "${_VK}" "WARN" "/proc/self/maps can be unreadable; that is not a defect"
t_assert_eq "" "$(printf '%s\n' "${_VK}" | grep -e '^FAIL')" "an unread maps file must not fail the image"

t_case "the loader's window-system extensions are asserted (CON41)"
t_assert_contains "${_VK}" "OK  the arm64 loader lists VK_KHR_surface VK_KHR_xcb_surface VK_KHR_xlib_surface VK_KHR_wayland_surface"

t_case "a loader without X11/XCB/Wayland surfaces FAILS -- the arm64 :latest of 2026-09-29"
_VK="$(_vk_shipped "${_VK_EXT_WSI_NONE}")"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader lacks VK_KHR_xcb_surface VK_KHR_xlib_surface VK_KHR_wayland_surface" \
  "every windowed test aborts on such a loader; the message must name exactly what is missing"
t_assert_eq "" "$(printf '%s\n' "${_VK}" | grep -e 'VK_KHR_surface VK_KHR_xcb' | grep -e '^FAIL')" \
  "VK_KHR_surface is present and must not be reported missing"

t_case "one missing surface is enough to fail"
_VK="$(_vk_shipped "${_VK_EXT_WSI_OK/ VK_KHR_wayland_surface/}")"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader lacks VK_KHR_wayland_surface --"

t_case "a surface name that is only a PREFIX of a listed one does not count"
_VK="$(_vk_shipped "${_VK_EXT_WSI_OK/ VK_KHR_surface / VK_KHR_surface_maintenance1 }")"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader lacks VK_KHR_surface --" \
  "VK_KHR_surface_maintenance1 is not VK_KHR_surface"

t_case "a loaded loader that listed no extensions FAILS rather than passing vacuously"
_VK="$(_vk_gate 'VKLIB /opt/vulkan/1.4.357.0/aarch64/lib/libvulkan.so.1.4.357
VKOK 1.4.357')"
t_assert_contains "${_VK}" "FAIL the arm64 Vulkan loader listed no instance extensions"

t_case "an unloadable libvulkan is still the hard failure it was"
_VK="$(_vk_gate 'OSError: libvulkan.so.1: cannot open shared object file: No such file or directory')"
t_assert_contains "${_VK}" "FAIL libvulkan.so.1 missing/unloadable" "the pre-existing arm must survive the sharpening"

t_case "every gate this suite pins is actually CALLED by the smoke"
# Driving an extracted gate proves the function, not that the smoke calls it.
_SMOKE_SRC="$(cat "${SMOKE}")"
for _g in check_consumer_contract check_flutter check_rust_toolchain check_manifest_tree_arch check_advertised_versions check_vulkan_loader; do
  t_assert_eq 1 "$(printf '%s\n' "${_SMOKE_SRC}" | grep -c "^    ${_g} \"\${image_tag}\"")" \
    "${_g} must be invoked once from the smoke's own call list"
done

t_case "the contract asserts every promise the consuming lane depends on"
# The suites iterate the row list, so a dropped row would take its guarantee with it silently.
for _r in ccache-dir sccache-dir rustup-tmp cargo-home android-home jdk appimagetool dart-tool flutter-owner ort-crate-env chrome android-emulator; do
  t_assert_contains " ${_CONSUMER_CONTRACT_ROWS} " " ${_r} " \
    "${_r} is a promise the consumer's acceptance check makes; it must stay in the table"
done

t_case "every contract row carries the consumer symptom it prevents"
# Without the symptom a red row names only our path, not what the consumer's log shows.
_CC_SYM="$(_extract _consumer_contract_symptom)"
for _r in ${_CONSUMER_CONTRACT_ROWS}; do
  t_assert_eq "" "$(bash -c "${_CC_SYM}"$'\n'"_consumer_contract_symptom ${_r}" | grep -e 'no symptom recorded')" \
    "row ${_r} has no symptom in _consumer_contract_symptom"
done

t_case "every per-arch exemption names a row that still exists"
# An arm for a deleted row silently narrows nothing and hides that it is dead.
_CC_EX="$(_extract _consumer_contract_exempt | sed -n 's/^ *\([a-z0-9|:-]*\)) return 0 ;;/\1/p' | tr '|' '\n' | sed 's/^[a-z0-9]*://')"
_t_all_present " ${_CONSUMER_CONTRACT_ROWS} " "${_CC_EX}" "-" \
  "every per-arch exemption must name a row the gate still asserts"

# G3: the ort crate env row as Dockerfile.package bakes it; see docs/consumer-image-contract.md
_CC_ORT_OK='ENV ort-lib-location /usr/local/lib/onnxruntime-cpu/lib
ENV ort-dylib-path /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so
ENV ort-prefer-dynamic 1
ENV ort-skip-download 1
ENV ort-lib-path <unset>
ENV cargo-net-offline <unset>
FACT ort-lib-real /usr/local/lib/onnxruntime-cpu/lib
FACT ort-dylib-real /usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so.1.30.0
FACT ort-link-lib yes
FACT ort-probe yes'
_CC_ORT_PARTS="$(_extract _consumer_contract_fact)
$(_extract _consumer_ort_env_problem)
$(_extract _consumer_ort_env_verdict)"
_ortv() { bash -c "${_CC_ORT_PARTS}"$'\n''_consumer_ort_env_verdict ort-crate-env "$1"' _ "$1" 2>&1; }
_ort_edit() { printf '%s\n' "${_CC_ORT_OK}" | sed -e "$1"; }
_ort_bad() { _ortv "$(_ort_edit "$1")"; }

t_case "G3: the chain lib dir, a dynamic link and a disarmed download hold the row"
t_assert_contains "$(_ortv "${_CC_ORT_OK}")" "OK ort-crate-env ORT_LIB_LOCATION -> /usr/local/lib/onnxruntime-cpu/lib" \
  "what Dockerfile.package bakes"
t_assert_contains "$(_ortv "$(_ort_edit 's/^ENV ort-skip-download 1/ENV ort-skip-download TRUE/')")" "OK ort-crate-env" \
  "ort-sys reads 'true' case-insensitively"
t_assert_contains "$(_ortv "$(_ort_edit 's#^ENV cargo-net-offline .*#ENV cargo-net-offline true#')")" "OK ort-crate-env" \
  "a truthy CARGO_NET_OFFLINE only disarms the download harder"
t_assert_contains "$(CC_PROBE="${_CC_ORT_OK}" bash -c "${_CC_PARTS}"$'\n'"${_CC_ORT_PARTS}"$'\n''_consumer_contract_verdicts amd64 "${CC_PROBE}"' 2>&1 \
  | grep -e '^OK ort-crate-env' || true)" "OK ort-crate-env" "the verdict table routes the row to its own verdict"

t_case "G3: every way back to pyke's ORT, or to a non-chain one, is BAD (mutation)"
_t_edit_table _ort_bad "BAD ort-crate-env " <<'ROWS'
s#^ENV ort-lib-location .*#ENV ort-lib-location#;s#^FACT ort-lib-real .*#FACT ort-lib-real#	ORT_LIB_LOCATION () resolves to nothing
s#^FACT ort-lib-real .*#FACT ort-lib-real /opt/opencv5/lib#	ORT_LIB_LOCATION (/usr/local/lib/onnxruntime-cpu/lib) resolves to /opt/opencv5/lib
s#^FACT ort-link-lib yes#FACT ort-link-lib no#	/usr/local/lib/onnxruntime-cpu/lib has no libonnxruntime.so
s#^FACT ort-dylib-real .*#FACT ort-dylib-real /opt/opencv5/lib/libonnxruntime.so.1.25.1#	ORT_DYLIB_PATH (/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so) resolves to /opt/opencv5/lib
s#^FACT ort-dylib-real .*#FACT ort-dylib-real#	ORT_DYLIB_PATH (/usr/local/lib/onnxruntime-cpu/lib/libonnxruntime.so) resolves to nothing
s#^ENV ort-prefer-dynamic 1#ENV ort-prefer-dynamic 0#	ENV ort-prefer-dynamic is "0"
/^ENV ort-skip-download/d	ENV ort-skip-download is ""
s#^ENV ort-skip-download 1#ENV ort-skip-download yes#	ENV ort-skip-download is "yes"
s#^ENV ort-lib-path .*#ENV ort-lib-path /root/.cache/ort.pyke.io#	ORT_LIB_PATH is set (/root/.cache/ort.pyke.io)
s#^ENV ort-lib-path .*#ENV ort-lib-path #	ORT_LIB_PATH is set ()
/^ENV ort-lib-path/d	ORT_LIB_PATH is set ()
s#^ENV cargo-net-offline .*#ENV cargo-net-offline false#	CARGO_NET_OFFLINE is falsy
s#^ENV cargo-net-offline .*#ENV cargo-net-offline #	CARGO_NET_OFFLINE is falsy
s#^ENV cargo-net-offline .*#ENV cargo-net-offline yes#	CARGO_NET_OFFLINE is falsy
ROWS

t_case "G3: a probe without its completion fact is NOFACT, never an empty-but-healthy env"
t_assert_contains "$(_ortv "$(_ort_edit '/^FACT ort-probe/d')")" "NOFACT ort-crate-env" \
  "a probe that never finished proves nothing, whatever lines it printed"

# Vulkan SDK toolset; tool lists and frozen floors are read from the smoke so the suite cannot drift
_VK_TOOL_VARS="$(grep -E '^_VK_(REQUIRED|REPORTED)_TOOLS=|^_VK_TOOLSET_FROZEN=' "${SMOKE}")"
eval "${_VK_TOOL_VARS}"
_vk_inventory() { for _t in $1; do printf 'TOOL %s\n' "${_t}"; done; }
# The counts a healthy arm64 prefix prints, so a case that is about TOOLS says so.
_vk_counts() { printf 'TOOLS %s\nLAYERS %s\nLAYER yes\n' "${1:-20}" "${2:-4}"; }
_vk_toolset() {
  VK_OUT="$1" bash -c '
    '"${_STUBS}"'
    '"${_VK_TOOL_VARS}"'
    _rt_run() { printf "%s\n" "${VK_OUT}"; }
    '"$(_extract _vk_toolset_floor)"'
    '"$(_extract _vk_floor_verdict)"'
    '"$(_extract check_vulkan_toolset)"'
    check_vulkan_toolset img '"${2:-arm64}"'' 2>&1
}

t_case "the shipped shape -- full libraries, two binaries -- fails"
t_assert_contains "$(_vk_toolset "TOOL glslangValidator
$(_vk_counts 2)")" \
  "missing required tools:" \
  "a prefix you can link against but cannot compile a shader with is the defect"

t_case "one absent required tool fails and names it"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS/spirv-val/}")
$(_vk_counts)")" \
  "spirv-val" "the gate must name what is missing, not just that something is"

t_case "the complete required set passes"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)")" \
  "SDK tools present" "what a correctly cross-built prefix prints"

t_case "an absent REPORTED tool warns and does not fail"
t_assert_eq "0" \
  "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)" | grep -c '^FAIL')" \
  "gfxrecon and friends are VK2 components; losing one is not a lane failure"

t_case "an absent reported tool is still visible as a WARN"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)")" \
  "WARN gfxrecon-info absent" "non-fatal must not mean invisible"

t_case "a missing validation layer manifest FAILS"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
TOOLS 20
LAYERS 4")" \
  "FAIL no validation layer manifest" "you cannot develop a Vulkan app without the layers"

t_case "the layer manifest is reported when the prefix carries it"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)")" "validation layer manifest present" "the good shape is stated too"

# Frozen floors: without a floor, a shrinking toolset passes
t_case "a prefix below its frozen tool count fails, and says what it is below"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 19)")" \
  "carries 19 tools, below its frozen floor of 20" \
  "a lane that LOSES tools while keeping the required names is the regression this catches"

t_case "fewer layer manifests than frozen fails too"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 20 3)")" \
  "carries 3 layer manifests, below its frozen floor of 4"

t_case "a prefix that GAINS tools passes and prints the floor to record"
_vk_out="$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 24)")"
t_assert_contains "${_vk_out}" "RATCHET: floor 20 -> 24" "a gain has to be recorded, not drift"
t_assert_eq "0" "$(printf '%s\n' "${_vk_out}" | grep -c '^FAIL')" "growing is not a failure"

t_case "amd64 carries the downloaded SDK and has its own, higher floor"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts 40 6)" amd64)" \
  "carries 40 tools, below its frozen floor of 52" \
  "one floor for all three arches would have to be the smallest, which asserts nothing about amd64"

t_case "an arch with no frozen row fails instead of inheriting silence"
t_assert_contains "$(_vk_toolset "$(_vk_inventory "${_VK_REQUIRED_TOOLS}")
$(_vk_counts)" ppc64le)" \
  "FAIL no _VK_TOOLSET_FROZEN row for ppc64le" \
  "a WARN here is the same silence the floors exist to end"

# llvm-target startability: the sdk walk resolves sonames on the builder, so only a runtime-side walk catches a missing one
_llvm_startable() {
  LT_OUT="$1" bash -c '
    '"${_STUBS}"'
    _rt_run() { printf "%s\n" "${LT_OUT}"; }
    '"$(_extract check_llvm_target_startable)"'
    check_llvm_target_startable img amd64' 2>&1
}

t_case "main() actually calls it -- a gate nothing invokes is not a gate"
t_assert_contains "$(grep -e '^    check_' "${SMOKE}")" "check_llvm_target_startable" \
  "the functional battery is the only place this runs; unwired it is 40 lines of dead text"

t_case "a clean prefix passes and says how many it walked"
t_assert_contains "$(_llvm_startable "COUNT 0 142")" "OK  0 of 142 llvm-target binaries"

t_case "the liblldb shape FAILS and names the binaries"
_lt_out="$(_llvm_startable "  BROKEN /usr/local/llvm-target/bin/lldb -> liblldb.so.22
  BROKEN /usr/local/llvm-target/bin/lldb-dap -> liblldb.so.22
  BROKEN /usr/local/llvm-target/bin/lldb-mcp -> liblldb.so.22
COUNT 3 142")"
t_assert_contains "${_lt_out}" "FAIL 3 of 142"
t_assert_contains "${_lt_out}" "BROKEN /usr/local/llvm-target/bin/lldb-dap -> liblldb.so.22" \
  "the operator needs the NAMES, not just the count"

t_case "a probe that did not run is not a clean prefix"
t_assert_contains "$(_llvm_startable "docker: no such container")" \
  "printed no COUNT" "an empty walk reads exactly like a healthy one unless the gate says otherwise"

t_case "an image without the prefix says so instead of failing"
_lt_out="$(_llvm_startable "ABSENT")"
t_assert_contains "${_lt_out}" "WARN /usr/local/llvm-target/bin absent"
t_assert_eq "0" "$(printf '%s\n' "${_lt_out}" | grep -c '^FAIL')"

# Android SDK ABI; the ABI->machine table is read from the smoke so the suite cannot drift
_ABI_TABLE="$(grep -E '^_ANDROID_ABI_MACHINE=' "${SMOKE}")"
_abi_gate() {
  ABI_OUT="$1" bash -c '
    '"${_STUBS}"'
    '"${_ABI_TABLE}"'
    _rt_run() { printf "%s\n" "${ABI_OUT}"; }
    '"$(_extract _android_abi_want)"'
    '"$(_extract check_android_abi)"'
    check_android_abi img "${ABI_ARCH:-arm64}"' 2>&1
}

# Machine 62 (x86-64) is the broken stage's output; 183 (AArch64) is the fixed one's.
_ABI_SAMPLE=/opt/android/litert/lib/libbenchmark_main.a
_abi_shipped="ABI arm64-v8a
MACH 62 420 ${_ABI_SAMPLE}"
_abi_fixed="ABI arm64-v8a
MACH 183 420 ${_ABI_SAMPLE}"

t_case "the shipped shape -- an arm64-v8a claim over an x86-64 payload -- fails"
t_assert_contains "$(_abi_gate "${_abi_shipped}")" \
  "is incompatible" "this is the consumer's link error, caught before it ships"

t_case "the failure names the count and a sample object"
t_assert_contains "$(_abi_gate "${_abi_shipped}")" \
  "420 object(s) of ELF machine 62" "a count and a path is what makes it actionable"

t_case "a correctly built arm64-v8a payload passes"
t_assert_contains "$(_abi_gate "${_abi_fixed}")" \
  "all arm64-v8a" "what the fixed android stage prints"

t_case "an image that does not advertise the ABI fails"
t_assert_contains "$(_abi_gate "ABI unset")" \
  "does not advertise ANDROID_TARGET_ABI" "a consumer cannot guess which ABI it got"

t_case "an ABI the table does not know fails rather than passing vacuously"
t_assert_contains "$(_abi_gate "ABI mips64
MACH 183 4 /opt/android/x")" "is not an ABI this gate knows" \
  "an unknown claim must never read as satisfied"

t_case "a mixed payload fails on the wrong half even when the right half is there"
t_assert_contains "$(_abi_gate "ABI arm64-v8a
MACH 183 400 /opt/android/ok.so
MACH 62 20 /opt/android/gstreamer/libgstreamer-1.0.a")" \
  "libgstreamer-1.0.a" "one stale ABI among many is exactly how it reached the consumer"

t_case "an empty tree warns instead of passing silently"
t_assert_contains "$(_abi_gate "ABI arm64-v8a")" \
  "no Android ELF objects" "nothing found is not the same as everything correct"

t_case "a payload-off image skips the ABI, and fails if /opt/android still ships objects"
t_assert_contains "$(_abi_gate "ABI arm64-v8a
OFF")" "SKIP the Android payload is off" "an arm64 image without the payload has no ABI to judge"
t_assert_contains "$(_abi_gate "ABI arm64-v8a
OFF
MACH 183 4 /opt/android/x.so")" "yet /opt/android carries 4 ELF object(s)" "a marker over a payload is a lie"

t_case "an amd64 image with the payload off fails: the Android lane builds there"
t_assert_contains "$(ABI_ARCH=amd64 _abi_gate "ABI arm64-v8a
OFF")" "the amd64 image carries no Android payload" "a HOST_PAYLOAD_ARCHES without amd64 must not publish green"

# An exemption is only legitimate when another gate, here check_android_abi, takes the tree over.
t_case "/opt/android is exempt from tree-arch and owned by the ABI gate instead"
_EXEMPT="$(grep -E '^_RT_TREE_ARCH_EXEMPT=' "${SMOKE}")"
t_assert_contains "${_EXEMPT}" "/opt/android" \
  "on amd64 an arm64-v8a payload is legitimately AArch64; tree-arch asks the wrong question"
t_assert_contains "$(_extract _android_abi_py)" "/opt/android" \
  "the exemption is only honest while the ABI gate actually walks that tree"
t_assert_contains "$(_extract check_android_abi)" "ANDROID_TARGET_ABI" \
  "and judges it against the ABI the image advertises, not against the image arch"

# check_consumer_contract's reader reports an unknown verb as a dropped row.
t_case "every verdict verb a producer emits is one the reader's case list handles"
_VERBS_READ="$(_extract check_consumer_contract | sed -n 's/^ *\([A-Z]\{2,\}\)).*/\1/p' | sort -u)"
_VERBS_EMITTED="$(for _f in _consumer_present_verdict _consumer_dir_verdict _consumer_jdk_verdict \
                            _consumer_tool_verdict _consumer_owner_verdict _consumer_android_verdict \
                            _consumer_exempt_verdict; do
    _extract "${_f}" 2>/dev/null | grep -o "printf '[A-Z]\{2,\}" | sed "s/printf '//"
  done | sort -u)"
_unknown=""
for _v in ${_VERBS_EMITTED}; do
  printf '%s\n' "${_VERBS_READ}" | grep -qx "${_v}" || _unknown="${_unknown} ${_v}"
done
t_assert_eq "" "${_unknown}" "a verb no case arm names is a row the gate silently drops"
t_assert_eq "0" "$(printf '%s\n' "${_VERBS_EMITTED}" | grep -c . 2>/dev/null | grep -x 0 || echo 0)" \
  "and the extraction must actually find verbs, or this case proves nothing"
