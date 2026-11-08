#!/usr/bin/env bash
# 35-build-migraphx-plugin-ep.sh's pins, seed gate, archive handling and library verdict; no download, no compiler, no GPU.
set -u
EP_SCRIPT=35-build-migraphx-plugin-ep.sh
# shellcheck source=linux/scripts/tests/plugin-ep-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/plugin-ep-fixture.sh"

# src/CMakeLists.txt of onnxruntime-ep-amdgpu at 58afd43b (2026-11-02), recorded: the eleven declarations, eigen/d3dx12/boost under if(USE_DML).
cp "${TESTS_DIR}/fixtures/onnxruntime-ep-amdgpu-CMakeLists.txt" "${_T}/CMakeLists.txt"
mgxep_declared_urls "${_T}/CMakeLists.txt" > "${_T}/declared.txt"

t_case "the parser reads every declaration, lower-cased, URL verbatim"
t_assert_eq 11 "$(wc -l < "${_T}/declared.txt")"
t_assert_eq "range-v3 https://github.com/ericniebler/range-v3/archive/refs/tags/0.12.0.zip" "$(grep '^range-v3 ' "${_T}/declared.txt")"
printf 'FetchContent_Declare(\n  Thing\n  GIT_REPOSITORY https://example.invalid/thing.git\n  GIT_TAG v1)\n' > "${_T}/git.txt"
t_assert_eq "thing git:https://example.invalid/thing.git" "$(mgxep_declared_urls "${_T}/git.txt")" "a git source is named, so the gate can refuse it"

t_case "versions.env's pins resolve to exactly the URLs upstream declares (the Linux twin of Assert-FetchContentSeeded)"
: > "${_T}/seeded.txt"
while IFS='|' read -r name vkey skey fmt; do
  spec="$(mgxep_seed_spec "${name}" "${vkey}" "${skey}" "${fmt}")" || t_fail "${name}: ${spec}"
  read -r _ url _ <<<"${spec}"
  [ "${name}" = absl ] || printf '%s %s\n' "${name}" "${url}" >> "${_T}/seeded.txt"
done < <(mgxep_seed_table)
t_assert_eq 8 "$(wc -l < "${_T}/seeded.txt")" "eight declared seeds; absl is protobuf's own fetch"
t_assert_eq "" "$(mgxep_assert_seeded "${_T}/declared.txt" "${_T}/seeded.txt" 'eigen d3dx12 boost' 2>&1)" "every active declaration is seeded at its own URL"

t_case "a missing, drifted or git-sourced declaration is refused by name; the inactive list is honoured"
grep -v '^json ' "${_T}/seeded.txt" > "${_T}/short.txt"
t_assert_contains "$(mgxep_assert_seeded "${_T}/declared.txt" "${_T}/short.txt" 'eigen d3dx12 boost' 2>&1)" "json (https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz) has no hash-pinned seed"
sed 's#fmt-12.1.0.zip#fmt-12.0.0.zip#' "${_T}/seeded.txt" > "${_T}/drift.txt"
t_assert_contains "$(mgxep_assert_seeded "${_T}/declared.txt" "${_T}/drift.txt" 'eigen d3dx12 boost' 2>&1)" "fmt is declared as https://github.com/fmtlib/fmt/releases/download/12.1.0/fmt-12.1.0.zip but the seed pins"
t_assert_contains "$(mgxep_assert_seeded "${_T}/declared.txt" "${_T}/seeded.txt" '' 2>&1)" "eigen (https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.zip) has no hash-pinned seed" \
  "without the inactive list the DML-only declarations count"
: > "${_T}/none.txt"
t_assert_contains "$(mgxep_assert_seeded "${_T}/none.txt" "${_T}/seeded.txt" '' 2>&1)" "no FetchContent_Declare found" "an empty declaration list is a moved layout, not a pass"

t_case "the seed gate and the spec read split on spaces under the media scripts' IFS (shell safety class 3)"
_ifs_seeded="$(IFS=$'\n\t'; while IFS='|' read -r name vkey skey fmt; do IFS=' ' read -r _ url _ < <(mgxep_seed_spec "${name}" "${vkey}" "${skey}" "${fmt}"); [ "${name}" = absl ] || printf '%s %s\n' "${name}" "${url}"; done < <(mgxep_seed_table))"
t_assert_eq "$(cat "${_T}/seeded.txt")" "${_ifs_seeded}" "the url column survives IFS=newline-tab"
t_assert_eq "" "$(IFS=$'\n\t'; mgxep_assert_seeded "${_T}/declared.txt" "${_T}/seeded.txt" 'eigen d3dx12 boost' 2>&1)" "the gate reads name and url apart under that IFS"
t_assert_contains "$(IFS=$'\n\t'; mgxep_assert_seeded "${_T}/declared.txt" "${_T}/short.txt" 'eigen d3dx12 boost' 2>&1)" "json (https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz) has no hash-pinned seed"

t_case "a pin that is empty, odd or not a sha256 is refused before any fetch"
t_assert_contains "$(ORT_AMDGPU_EP_FMT_VERSION='' mgxep_seed_spec fmt ORT_AMDGPU_EP_FMT_VERSION ORT_AMDGPU_EP_FMT_SHA256 'x{0}' 2>&1)" "ORT_AMDGPU_EP_FMT_VERSION is not set"
t_assert_contains "$(ORT_AMDGPU_EP_FMT_VERSION='12.1.0;rm -rf' mgxep_seed_spec fmt ORT_AMDGPU_EP_FMT_VERSION ORT_AMDGPU_EP_FMT_SHA256 'x{0}' 2>&1)" "is not a plain version token"
t_assert_contains "$(ORT_AMDGPU_EP_FMT_SHA256=abc mgxep_seed_spec fmt ORT_AMDGPU_EP_FMT_VERSION ORT_AMDGPU_EP_FMT_SHA256 'x{0}' 2>&1)" "is not a 64-hex sha256"
t_assert_eq "https://github.com/onnxruntime/onnxruntime-ep-amdgpu/archive/${ORT_AMDGPU_EP_COMMIT}.tar.gz" "$(mgxep_source_url "${ORT_AMDGPU_EP_COMMIT}")"
t_assert_eq "FETCHCONTENT_SOURCE_DIR_RANGE-V3" "$(mgxep_seed_define range-v3)" "CMake upper-cases the name and keeps the dash"

t_case "archives extract to their single top-level directory; two top-level entries are refused"
mkdir -p "${_T}/one/pkg-1.0/sub" && printf 'MIT\n' > "${_T}/one/pkg-1.0/LICENSE" && (cd "${_T}/one" && tar -czf ../one.tar.gz pkg-1.0)
mgxep_extract "${_T}/one.tar.gz" "${_T}/seeds/one" && t_assert_eq "MIT" "$(cat "${_T}/seeds/one/LICENSE")"
mkdir -p "${_T}/two/a" "${_T}/two/b" && (cd "${_T}/two" && tar -czf ../two.tar.gz a b)
t_assert_contains "$(mgxep_extract "${_T}/two.tar.gz" "${_T}/seeds/two" 2>&1)" "does not hold one top-level directory"
if command -v zip >/dev/null 2>&1; then
  (cd "${_T}/one" && zip -qr ../one.zip pkg-1.0) && mgxep_extract "${_T}/one.zip" "${_T}/seeds/onez" && t_assert_eq "MIT" "$(cat "${_T}/seeds/onez/LICENSE")"
fi

t_case "a seed goes through download_verified_file with its pinned sha256, then lands under seeds/<name>"
download_verified_file() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${_T}/fetched"; cp "${_T}/one.tar.gz" "$3"; }
dir="$(mgxep_fetch_seed fmt https://example.invalid/fmt-12.1.0.tar.gz "$(printf 'a%.0s' {1..64})" "${_T}/w")"
t_assert_eq "${_T}/w/seeds/fmt" "${dir}"
t_assert_eq "https://example.invalid/fmt-12.1.0.tar.gz $(printf 'a%.0s' {1..64}) ${_T}/w/dl/fmt-12.1.0.tar.gz" "$(cat "${_T}/fetched")"

t_case "fetching every seed leaves the caller's sha alone (the first proof image recorded absl's hash as the source's)"
mgxep_fetch_seed() { printf '%s %s\n' "$1" "$3" >> "${_T}/all-fetched"; printf '%s/seeds/%s\n' "$4" "$1"; }
sha="source-sha"; declare -a defs=()
mgxep_seed_all "${_T}/all" "${_T}/all-seeded.txt" defs
t_assert_eq "source-sha" "${sha}"
t_assert_eq 9 "${#defs[@]}" "one define per pinned seed, absl included"
t_assert_eq "$(cat "${_T}/seeded.txt")" "$(cat "${_T}/all-seeded.txt")" "the seeded list the gate reads"
t_assert_contains "${defs[*]}" "-DFETCHCONTENT_SOURCE_DIR_RANGE-V3:PATH=${_T}/all/seeds/range-v3"
t_assert_eq "fmt ${ORT_AMDGPU_EP_FMT_SHA256}" "$(grep '^fmt ' "${_T}/all-fetched")" "each seed is fetched under its own pin"

t_case "the ORT prefix gives find_package an imported target over the chain's versioned library"
mkdir -p "${_T}/ort/lib" "${_T}/ort/include" && : > "${_T}/ort/include/onnxruntime_c_api.h" && printf 'x' > "${_T}/ort/lib/libonnxruntime.so.1.31.1"
p="$(mgxep_ort_prefix "${_T}/ort" "${_T}/ortp")"
t_assert_contains "$(cat "${p}/lib/cmake/onnxruntime/onnxruntimeConfig.cmake")" "IMPORTED_LOCATION \"${_T}/ort/lib/libonnxruntime.so.1.31.1\""
t_assert_eq "${_T}/ort/lib/libonnxruntime.so.1.31.1" "$(readlink -f "${p}/lib/libonnxruntime.so.1")" "the SONAME link the module NEEDs"
t_assert_eq "${_T}/ort/lib/libonnxruntime.so.1.31.1" "$(readlink -f "${p}/lib/libonnxruntime.so")" "the unversioned name the TensorRT plugin's find_library wants"
t_assert_eq /usr/local/lib/onnxruntime-cpu "${MGXEP_ORT_DIR}" "the rocm image's only ORT is the CPU build"
rm -rf "${_T}/noort"; mkdir -p "${_T}/noort/lib"
t_assert_contains "$(mgxep_ort_prefix "${_T}/noort" "${_T}/noortp" 2>&1)" "no libonnxruntime.so.N"

t_case "the export check survives a module with thousands of dynamic symbols under pipefail (grep -q closed the pipe on the TensorRT plugin)"
# A readelf stand-in that names the first entry point early and then writes far past the pipe buffer: a -q grep's early exit kills it with SIGPIPE.
printf 'x' > "${_T}/big.so"
t_assert_eq 0 "$(bash -c 'set -o pipefail; source "$1"; readelf() { printf "   2: 0 0 FUNC GLOBAL DEFAULT 11 CreateEpFactories\n"; seq 1 200000 | sed "s/^/   1: 0 0 FUNC GLOBAL DEFAULT 11 sym/"; printf "   3: 0 0 FUNC GLOBAL DEFAULT 11 ReleaseEpFactory@@VERS_1.0\n"; }; plugin_ep_exports_ok "$2"; echo $?' _ "${EP}" "${_T}/big.so" 2>&1 | tail -n 1)" "both exports found, no SIGPIPE"

t_case "the library verdict wants both plugin exports and a resolvable closure"
mkdir -p "${_T}/bin"; printf 'x' > "${_T}/libmigraphx-ep.so"
cat > "${_T}/bin/readelf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_EXPORTS:-}" | tr ' ' '\n' | sed 's/^/   1: 0000 0 FUNC GLOBAL DEFAULT 1 /'
EOF
cat > "${_T}/bin/ldd" <<'EOF'
#!/usr/bin/env bash
printf '\tlibmigraphx_c.so.3 => /opt/rocm/lib/libmigraphx_c.so.3 (0x1)\n'
[ -z "${FAKE_MISSING:-}" ] || printf '\t%s => not found\n' "${FAKE_MISSING}"
EOF
chmod +x "${_T}/bin/readelf" "${_T}/bin/ldd"
_v() { PATH="${_T}/bin:${PATH}" FAKE_EXPORTS="$1" FAKE_MISSING="$2" mgxep_verify_library "${_T}/libmigraphx-ep.so" 2>&1; }
t_assert_eq "" "$(_v 'CreateEpFactories ReleaseEpFactory' '')"
t_assert_eq "" "$(_v 'CreateEpFactories@@VERS_1.0 ReleaseEpFactory@@VERS_1.0 GetBackendTelemetry@@VERS_1.0' '')" "the version script tags the exports; the first rocm chain failed on the bare pattern"
t_assert_contains "$(_v 'CreateEpFactoriesX@@VERS_1.0 ReleaseEpFactory@@VERS_1.0' '')" "does not export CreateEpFactories"
t_assert_contains "$(_v 'CreateEpFactories' '')" "does not export ReleaseEpFactory"
t_assert_contains "$(_v 'CreateEpFactories ReleaseEpFactory' 'libonnxruntime.so.1')" "cannot resolve: libonnxruntime.so.1"
t_assert_contains "$(mgxep_verify_library "${_T}/absent.so" 2>&1)" "is missing"

t_case "outside the rocm variant the build step only leaves the empty output tree the media merge COPYs"
t_assert_eq "Skipping the MIGraphX plugin EP (ENABLE_AMD=false)" "$(MGXEP_OUTPUT_DIR="${_T}/placeholder" ENABLE_AMD=false mgxep_build 2>&1)"
t_assert_ok test -d "${_T}/placeholder"
t_assert_eq "" "$(ls -A "${_T}/placeholder")" "nothing is built"

t_case "the plugin reaches the merged media image: run unconditionally in the GPU RUN, copied by the merge stage (the first rocm proof image lacked it)"
_df="${TESTS_DIR}/../../Dockerfile.media"
t_assert_eq 1 "$(grep -cE '^COPY --link --from=onnxruntime /usr/local/lib/onnxruntime-ep-amdgpu /usr/local/lib/onnxruntime-ep-amdgpu$' "${_df}")" "the merge stage copies the plugin tree"
t_assert_eq "    bash /opt/scripts/03-media/build/onnxruntime/build/35-build-migraphx-plugin-ep.sh build; \\" "$(grep -E '35-build-migraphx-plugin-ep.sh build' "${_df}")" "the call sits after the GPU if/fi, so every chain leaves the tree"

t_summary
