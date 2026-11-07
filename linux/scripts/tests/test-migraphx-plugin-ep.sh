#!/usr/bin/env bash
# 35-build-migraphx-plugin-ep.sh's pins, seed gate, archive handling and library verdict; no download, no compiler, no GPU.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
EP="${TESTS_DIR}/../03-media/build/onnxruntime/build/35-build-migraphx-plugin-ep.sh"
ENVF="${TESTS_DIR}/../01-core/versions.env"
_T="$(mktemp -d)"
trap 'rm -rf "${_T}"' EXIT
# shellcheck source=../03-media/build/onnxruntime/build/35-build-migraphx-plugin-ep.sh
source "${EP}"
# shellcheck source=../01-core/load-versions-env.sh
source "${TESTS_DIR}/../01-core/load-versions-env.sh"
load_versions_env "${ENVF}"

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

t_case "a pin that is empty, odd or not a sha256 is refused before any fetch"
t_assert_contains "$(ORT_AMDGPU_EP_FMT_VERSION= mgxep_seed_spec fmt ORT_AMDGPU_EP_FMT_VERSION ORT_AMDGPU_EP_FMT_SHA256 'x{0}' 2>&1)" "ORT_AMDGPU_EP_FMT_VERSION is not set"
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

t_case "the ORT prefix gives find_package an imported target over the chain's versioned library"
mkdir -p "${_T}/ort/lib" "${_T}/ort/include" && : > "${_T}/ort/include/onnxruntime_c_api.h" && printf 'x' > "${_T}/ort/lib/libonnxruntime.so.1.31.1"
p="$(mgxep_ort_prefix "${_T}/ort" "${_T}/ortp")"
t_assert_contains "$(cat "${p}/lib/cmake/onnxruntime/onnxruntimeConfig.cmake")" "IMPORTED_LOCATION \"${_T}/ort/lib/libonnxruntime.so.1.31.1\""
t_assert_eq "${_T}/ort/lib/libonnxruntime.so.1.31.1" "$(readlink -f "${p}/lib/libonnxruntime.so.1")" "the SONAME link the module NEEDs"
rm -rf "${_T}/noort"; mkdir -p "${_T}/noort/lib"
t_assert_contains "$(mgxep_ort_prefix "${_T}/noort" "${_T}/noortp" 2>&1)" "no libonnxruntime.so.N"

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
t_assert_contains "$(_v 'CreateEpFactories' '')" "does not export ReleaseEpFactory"
t_assert_contains "$(_v 'CreateEpFactories ReleaseEpFactory' 'libonnxruntime.so.1')" "cannot resolve: libonnxruntime.so.1"
t_assert_contains "$(mgxep_verify_library "${_T}/absent.so" 2>&1)" "is missing"

t_case "the build step is a no-op outside the rocm variant"
t_assert_eq "Skipping the MIGraphX plugin EP (ENABLE_AMD=false)" "$(ENABLE_AMD=false mgxep_build 2>&1)"

t_summary
