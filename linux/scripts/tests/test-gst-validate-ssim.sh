#!/usr/bin/env bash
# The SSIM validate plugin no longer blacklists itself, and the smoke fails a blacklisted plugin (CON47); fake gst binaries, so a real registry is not scanned here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
PATCHER="${SCRIPTS}/03-media/build/gstreamer/common/patch-gstreamer-sources.sh"
PATCH="${SCRIPTS}/patches/gstreamer/007-validate-ssim-register-outside-validate.patch"
RT_SMOKE="${SCRIPTS}/06-packaging/smoke-runtime-image.sh"
SSIM_C="subprojects/gst-devtools/validate/plugins/ssim/gstvalidatessim.c"

_SB="$(mktemp -d)"; trap 'rm -rf "${_SB}"' EXIT

t_case "the GStreamer patcher applies 007 when gst-devtools is in the tree"
_fn="$(t_fn_src "${PATCHER}" patch_gstreamer_sources)" || exit 1
t_assert_contains "${_fn}" '"${_patch_dir}/007-validate-ssim-register-outside-validate.patch"'

# Upstream 1.29.2's context around the check, as the patch expects it.
mkdir -p "${_SB}/src/$(dirname "${SSIM_C}")"
cat > "${_SB}/src/${SSIM_C}" <<'C'
static gboolean
gst_validate_ssim_init (GstPlugin * plugin)
{
  GList *tmp, *config;
  GstStructure *config_structure = NULL;

  if (!gst_validate_is_initialized ())
    return FALSE;

  config = gst_validate_plugin_get_config (plugin);
  for (tmp = config; tmp; tmp = tmp->next) {
C
git -C "${_SB}/src" init -q

t_case "007 makes plugin_init succeed outside gst-validate, once"
_out="$(bash "${PATCHER}" "${_SB}/src" 2>&1)"
t_assert_contains "${_out}" "APPLIED: gst-devtools ssim plugin registers outside gst-validate"
t_assert_contains "$(sed -n '/gst_validate_is_initialized/,+1p' "${_SB}/src/${SSIM_C}")" "return TRUE;" \
  "FALSE blacklists the plugin in every core registry scan"
t_assert_contains "$(bash "${PATCHER}" "${_SB}/src" 2>&1)" "SKIP: gst-devtools ssim plugin" "idempotent"
t_assert_eq "1" "$(grep -c '^-    return FALSE;$' "${PATCH}")" "the patch flips exactly that return"

_RT="$(t_rt_sandbox)"; trap 'rm -rf "${_SB}" "${_RT}"' EXIT
mkdir -p "${_SB}/bin"
cat > "${_SB}/bin/gst-inspect-1.0" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -b ] || exit 0
echo "Blacklisted files:"
for f in ${FAKE_BLACKLIST:-}; do echo "  ${f}"; done
# A plugin linking the driver libcuda loads only when a libcuda.so.1 is on the loader path.
_cuda=""; for d in $(printf '%s' "${LD_LIBRARY_PATH:-}" | tr ':' ' '); do [ -e "${d}/libcuda.so.1" ] && _cuda=1; done
[ -n "${_cuda}" ] || for f in ${FAKE_NEEDS_CUDA:-}; do echo "  ${f}"; done
echo ""
echo "Total count: $(echo ${FAKE_BLACKLIST:-} | wc -w) blacklisted files"
SH
cat > "${_SB}/bin/gst-validate-1.0" <<'SH'
#!/usr/bin/env bash
d="${GST_VALIDATE_CONFIG##*output-dir=}"
for i in $(seq 1 "${FAKE_FRAMES:-0}"); do : > "${d}/${i}.png"; done
SH
chmod +x "${_SB}/bin/"*
# Runs the real in-image probe body under bash -c, fakes first on PATH; $1 = the call, $2 = shell run before it.
_probe() {
  bash -c "source '${_RT}/rt.sh' >/dev/null 2>&1
${2:-}
_rt_run() { shift 2; PATH='${_SB}/bin':\"\${PATH}\" bash -c \"\$@\"; }
$1; echo \"FAILURES=\${FAILURES}\"" 2>&1
}

t_case "the plugin-health check reads the registry blacklist"
t_assert_contains "$(t_rt_recorded "${_RT}" $'GST_SCAN_DONE\nBLACKLISTED libgstvalidatessim.so\nGST_BLACKLIST_DONE' \
  check_gstreamer_plugin_health img amd64)" "FAILURES=1" "a clean scanner pass does not excuse a blacklisted plugin"
t_assert_contains "$(t_fn_src "${RT_SMOKE}" main)" 'check_gst_validate_ssim "${image_tag}" "${target_arch}"'

t_case "an empty blacklist passes; a blacklisted plugin fails by name"
t_assert_contains "$(FAKE_BLACKLIST='' _probe '_gst_check_blacklist amd64')" "FAILURES=0"
_out="$(FAKE_BLACKLIST='libgstvalidatessim.so' _probe '_gst_check_blacklist amd64')"
t_assert_contains "${_out}" "FAILURES=1" "the published :latest amd64 of 2026-09-30"
t_assert_contains "${_out}" "blacklists libgstvalidatessim.so on amd64"

t_case "a documented exception is reported, not failed; an unreadable blacklist fails"
_out="$(FAKE_BLACKLIST='libgstgtk4.so' _probe '_gst_check_blacklist arm64' "_PARITY_GST_KNOWN_BROKEN='arm64:libgstgtk4.so'")"
t_assert_contains "${_out}" "FAILURES=0"
t_assert_contains "${_out}" "documented arm64 exception"
t_assert_contains "$(t_rt_recorded "${_RT}" '' _gst_check_blacklist amd64)" "FAILURES=1"

t_case "a GPU-less nvidia image scans with the CUDA driver stubs, so only a real load failure is blacklisted"
mkdir -p "${_SB}/cuda/lib64/stubs" "${_SB}/noldc"
: > "${_SB}/cuda/lib64/stubs/libcuda.so"; : > "${_SB}/cuda/lib64/stubs/libnvidia-ml.so"
printf '#!/usr/bin/env bash\n' > "${_SB}/noldc/ldconfig"; chmod +x "${_SB}/noldc/ldconfig"
_nv="export CUDA_HOME='${_SB}/cuda' LD_LIBRARY_PATH= PATH='${_SB}/noldc':\"\${PATH}\""
_out="$(FAKE_NEEDS_CUDA='libnvdsgst_infer.so libgstnvvideoconvert.so' _probe '_gst_check_blacklist amd64' "${_nv}")"
t_assert_contains "${_out}" "FAILURES=0"
t_assert_contains "${_out}" "scanned with the CUDA driver stubs"
_out="$(FAKE_NEEDS_CUDA='libnvdsgst_infer.so' _probe '_gst_check_blacklist amd64' "export CUDA_HOME='${_SB}/nocuda' LD_LIBRARY_PATH=")"
t_assert_contains "${_out}" "blacklists libnvdsgst_infer.so on amd64" "without stubs a driver-linked plugin stays blacklisted"
_out="$(FAKE_BLACKLIST='libnvdsgst_ucx.so libgstfoo.so' _probe '_gst_check_blacklist amd64' "${_nv}")"
t_assert_contains "${_out}" "libnvdsgst_ucx.so is blacklisted -- documented: libucs.so.0 is not shipped"
t_assert_contains "${_out}" "blacklists libgstfoo.so on amd64" "a stub never excuses another plugin"

t_case "the blacklist is read even when the scanner pass did not complete"
t_assert_contains "$(t_rt_recorded "${_RT}" $'BLACKLISTED libgstvalidatessim.so\nGST_BLACKLIST_DONE' \
  check_gstreamer_plugin_health img amd64)" "FAILURES=1"

t_case "gst-validate's SSIM override must write frames on amd64; cross arches ship no devtools"
t_assert_contains "$(FAKE_FRAMES=3 _probe 'check_gst_validate_ssim img amd64')" "FAILURES=0"
t_assert_contains "$(FAKE_FRAMES=0 _probe 'check_gst_validate_ssim img amd64')" "FAILURES=1"
_out="$(t_rt_recorded "${_RT}" NO_VALIDATE 'for a in amd64 arm64 riscv64; do check_gst_validate_ssim img ${a}; done')"
t_assert_contains "${_out}" "FAILURES=1" "only amd64 must ship it"
t_assert_contains "${_out}" "no gst-devtools on riscv64"

t_summary
