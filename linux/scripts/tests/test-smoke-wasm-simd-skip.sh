#!/usr/bin/env bash
# smoke-media.sh's WASM engine-compile gate: a SIMD-free node skips with one line; a corrupt module still fails (CON154).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

FN="$(t_fn_src "${TESTS_DIR}/../06-packaging/smoke-media.sh" _web_wasm_node_compile)" || exit 1
pass() { echo "PASS $*"; }

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT
mkdir -p "${_WORK}/simd" "${_WORK}/bad" "${_WORK}/bin"
# One module with a v128 function (valid only with SIMD), and one file that is not wasm at all.
printf '\x00asm\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7b\x03\x02\x01\x00\x0a\x0a\x01\x08\x00\x41\x00\xfd\x0f\xfd\x62\x0b' > "${_WORK}/simd/ok.wasm"
printf 'not wasm' > "${_WORK}/bad/corrupt.wasm"

# Stand-in for a SIMD-free node: the probe's WebAssembly.validate answers false when SIMULATE_NO_SIMD=1.
printf '%s\n' 'if (process.env.SIMULATE_NO_SIMD === "1") WebAssembly.validate = () => false;' > "${_WORK}/no-simd.js"
REAL_NODE="$(command -v node)"
printf '#!/usr/bin/env bash\nexec "%s" --require "%s" "$@"\n' "${REAL_NODE}" "${_WORK}/no-simd.js" > "${_WORK}/bin/node"
chmod +x "${_WORK}/bin/node"

eval "${FN}"
export PATH="${_WORK}/bin:${PATH}"

t_case "a SIMD engine compiles the module and passes"
out="$(_web_wasm_node_compile "LiteRT.js" "${_WORK}/simd" 2>&1)"
t_assert_contains "${out}" "PASS LiteRT.js WASM engine-compiles"

t_case "a SIMD-free engine prints one SKIP line, not a FAILED line per module"
out="$(SIMULATE_NO_SIMD=1 _web_wasm_node_compile "LiteRT.js" "${_WORK}/simd" 2>&1)"
t_assert_contains "${out}" "SKIP LiteRT.js: no WASM SIMD in this node, 1 module(s) not engine-compiled"
t_assert_eq "0" "$(printf '%s\n' "${out}" | grep -c 'engine-compile FAILED')"
t_assert_eq "0" "$(printf '%s\n' "${out}" | grep -c 'PASS')"

t_case "a corrupt module with SIMD present still fails and warns"
out="$(_web_wasm_node_compile "LiteRT.js" "${_WORK}/bad" 2>&1)"
t_assert_contains "${out}" "wasm engine-compile FAILED: corrupt.wasm"
t_assert_contains "${out}" "WARN: LiteRT.js has WASM the engine rejects"

t_summary
