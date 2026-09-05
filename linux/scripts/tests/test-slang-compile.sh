#!/usr/bin/env bash
# Characterisation of lib/slang-compile.sh's combined-WGSL emit, driven by a
# fixture manifest and a fake slangc — the four outcomes of one wgslMap row
# (copied / emit failed / rejected / source absent), the toolchain floor and
# the depth-texture patch table.
# docs/slang-shader-compilation.md#the-combined-emit-outcomes
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${TESTS_DIR}/../lib/slang-compile.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/shaders/common" "${_work}/bin" "${_work}/crate"
printf 'void main() {}\n' > "${_work}/shaders/main.slang"

cat > "${_work}/bin/slangc" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "-version" ] && { printf '%s\n' "${FAKE_SLANGC_VERSION}"; exit 0; }
_out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) _out="$2"; shift 2 ;; *) shift ;; esac
done
[ "${FAKE_SLANGC_RC:-0}" -ne 0 ] && exit "${FAKE_SLANGC_RC}"
cat "${FAKE_WGSL_PAYLOAD}" > "${_out}"
FAKE
chmod +x "${_work}/bin/slangc"

cat > "${_work}/valid.wgsl" <<'W'
struct VSOut
{
  @builtin(position) pos : vec4<f32>,
  @location(0) uv : vec2<f32>,
}
var shadowMap : texture_depth_2d;
W
cat > "${_work}/invalid.wgsl" <<'W'
struct VSOut
{
  @builtin(position) pos : vec4<f32>,
  uv : vec2<f32>,
}
W

# $1 = wgslMap src (a name that may not exist), $2... = patch rows as JSON
_manifest() {
  local src="$1" patches="${2:-[]}" floor="${3:-2026.8}"
  cat > "${_work}/manifest.json" <<J
{
  "manifest": [],
  "wgslMap": [ { "src": "${src}", "out": "shader.wgsl", "dst": "crate" } ],
  "depthTexturePatches": { "shader.wgsl": ${patches} },
  "minSlangcVersionForWgsl": "${floor}"
}
J
}

_run() {
  (
    cd "${_work}" || exit 9
    export FAKE_SLANGC_VERSION="${VER}" FAKE_SLANGC_RC="${RC}"
    export FAKE_WGSL_PAYLOAD="${_work}/${PAYLOAD}"
    export VULKAN_SDK="" PATH="${_work}/bin:${PATH}"
    export SLANG_COMPILE_SOURCE_ROOT="${_work}/shaders"
    export SLANG_COMPILE_MANIFEST="${_work}/manifest.json"
    export SLANG_COMPILE_DEST_ROOT="${_work}"
    set -e
    # shellcheck source=../lib/slang-compile.sh
    source "${LIB}"
    slang_compile_main
  ) > "${_work}/out.txt" 2>&1
  _rc_v=$?
  _out="$(cat "${_work}/out.txt")"
}

# Every case starts from the same fixture state AND the same fake-slangc knobs:
# a leaked knob is how a suite like this goes quietly green on the wrong path.
_reset() {
  rm -rf "${_work}/crate" "${_work}/shaders/build"
  mkdir -p "${_work}/crate"
  VER=2026.8 RC=0 PAYLOAD=valid.wgsl
}
_dst="${_work}/crate/shader.wgsl"
# t_assert_ok takes a COMMAND and no message; a message argument would silently
# become a third argument to test(1) and pass for the wrong reason.
_dst_state() { if [ -f "${_dst}" ]; then echo present; else echo absent; fi; }

t_case "a valid emit is patched, validated and COPIED to the manifest's dst"
_reset
_manifest main.slang '[ { "pattern": "texture_depth_2d", "replacement": "texture_2d<f32>" } ]'
_run
t_assert_eq "0" "${_rc_v}"
t_assert_eq "present" "$(_dst_state)"
t_assert_contains "${_out}" "1 combined WGSL file(s)"
t_assert_contains "$(cat "${_dst}")" "texture_2d<f32>" "the patch table rewrites the emit before the copy"

t_case "a patch that matches NOTHING warns: slangc output moved under the pattern"
_reset
_manifest main.slang '[ { "pattern": "this_token_is_not_in_the_emit", "replacement": "x" } ]'
_run
t_assert_contains "${_out}" "matched nothing"
t_assert_eq "present" "$(_dst_state)"  "a dead patch is a warning, not a refusal"

t_case "a FAILED emit is reported and nothing is copied"
_reset
RC=1
_manifest main.slang
_run
t_assert_contains "${_out}" "Combined WGSL emit failed for 1 file(s)"
t_assert_eq "absent" "$(_dst_state)"  "a failed slangc must never leave a stale destination file"

t_case "an emit with an unattributed varying member is REJECTED and exits 1"
_reset
PAYLOAD=invalid.wgsl
_manifest main.slang
_run
t_assert_eq "1" "${_rc_v}" "an invalid emit is a toolchain regression, not a warning"
t_assert_contains "${_out}" "shader.wgsl: slangc"
t_assert_contains "${_out}" "NOT overwritten"
t_assert_eq "absent" "$(_dst_state)"  "the checked-in WGSL must survive a bad emit"

t_case "a wgslMap row naming a source that is not there is skipped silently"
_reset
_manifest gone.slang
_run
t_assert_eq "0" "${_rc_v}"
t_assert_contains "${_out}" "0 combined WGSL file(s)"
t_assert_eq "absent" "$(_dst_state)"

t_case "below the manifest's slangc floor the emit is SKIPPED, not attempted"
_reset
VER=2026.1-52-gc8ddf20bb
_manifest main.slang '[]' 2026.8
_run
t_assert_eq "0" "${_rc_v}"
t_assert_contains "${_out}" "SKIPPING the combined WGSL emit"
t_assert_eq "absent" "$(_dst_state)"  "the checked-in WGSL is left untouched below the floor"

t_case "at or above the floor the emit runs"
_reset
VER=2026.9
_manifest main.slang '[]' 2026.8
_run
t_assert_eq "0" "${_rc_v}"
t_assert_eq "present" "$(_dst_state)"

t_summary
