#!/usr/bin/env bash
# fetch-data-lock.py and KataglyphisFetchData.cmake over file:// locks: cache, hash checks, atomic writes, scene stamp. See docs/data-repositories.md#the-hubs-fetcher
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
FETCH="${TESTS_DIR}/../lib/fetch-data-lock.py"
CMAKE_MODULES="$(cd "${TESTS_DIR}/../../../cmake" && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"

t_skip_unless "a POSIX python3" t_posix_python
t_skip_unless "tar" command -v tar

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
rel="${w}/release"
mkdir -p "${rel}/pack/scene/sub" "${rel}/stray"
printf 'model-bytes' > "${rel}/model.onnx"
printf 'license' > "${rel}/model.LICENSE"
printf 'a' > "${rel}/pack/scene/a.txt"
printf 'b' > "${rel}/pack/scene/sub/b.txt"
printf 's' > "${rel}/stray/stray.txt"
tar --mtime=@0 -cJf "${rel}/scene.tar.xz" -C "${rel}/pack" scene
tar -cJf "${rel}/bad.tar.xz" -C "${rel}/pack" scene -C "${rel}/stray" stray.txt

sha() { sha256sum "$1" | cut -d' ' -f1; }
# line <file> [url]: one lock line for a release file.
line() { printf '%s  %s  %s\n' "$(sha "${rel}/$1")" "$1" "${2:-file://${rel}/$1}"; }
{ printf '# sha256 file url\n\n'; line model.onnx; line model.LICENSE; } > "${w}/models.lock"
{ line scene.tar.xz; line bad.tar.xz; } > "${w}/assets.lock"
fetch() { "${PY}" -I "${FETCH}" --cache "${w}/cache" "$@" > "${w}/log" 2>&1; }
log() { cat "${w}/log"; }
fetch_private() { (umask 077 && fetch "$@"); }
model_sha="$(sha "${rel}/model.onnx")"

t_case "every file of the lock lands in --dest by one rename, readable by every user, through the cache"
t_assert_ok fetch_private --lock "${w}/models.lock" --dest "${w}/d1"
t_assert_eq model-bytes "$(cat "${w}/d1/model.onnx" 2>&1)"
t_assert_eq license "$(cat "${w}/d1/model.LICENSE" 2>&1)"
t_assert_eq 644 "$(stat -c %a "${w}/d1/model.onnx")"
t_assert_ok test -f "${w}/cache/${model_sha}-model.onnx"
t_assert_eq 0 "$(find "${w}/d1" "${w}/cache" -name '*.part*' | wc -l | tr -d ' ')"

t_case "without --dest the files go beside the lock"
mkdir -p "${w}/beside"
cp "${w}/models.lock" "${w}/beside/"
t_assert_ok fetch --lock "${w}/beside/models.lock"
t_assert_ok test -f "${w}/beside/model.onnx"

t_case "a matching target is not written again; the cache serves when the release is gone"
t_assert_ok fetch --lock "${w}/models.lock" --dest "${w}/d1"
t_assert_eq "" "$(log)"
mv "${rel}" "${rel}.gone"
t_assert_ok fetch --lock "${w}/models.lock" --dest "${w}/d2"
t_assert_eq model-bytes "$(cat "${w}/d2/model.onnx" 2>&1)"
mkdir -p "${w}/old-cache"
cp "${rel}.gone/model.onnx" "${w}/old-cache/${model_sha}"
t_assert_ok "${PY}" -I "${FETCH}" --cache "${w}/old-cache" --lock "${w}/models.lock" --dest "${w}/d3" --only model.onnx
t_assert_ok test -f "${w}/d3/model.onnx"
mv "${rel}.gone" "${rel}"

t_case "a changed target and a corrupt cached copy are both replaced by the locked bytes"
printf 'changed' > "${w}/d1/model.onnx"
printf 'corrupt' > "${w}/cache/${model_sha}-model.onnx"
t_assert_ok fetch --lock "${w}/models.lock" --dest "${w}/d1"
t_assert_eq model-bytes "$(cat "${w}/d1/model.onnx" 2>&1)"
t_assert_eq model-bytes "$(cat "${w}/cache/${model_sha}-model.onnx" 2>&1)"

t_case "a download with another hash fails and leaves neither the target nor a part behind"
line model.onnx "file://${rel}/model.LICENSE" > "${w}/wrong.lock"
rm -f "${w}/cache/${model_sha}-model.onnx"
t_assert_fails fetch --lock "${w}/wrong.lock" --dest "${w}/d4"
t_assert_contains "$(log)" "the lock says ${model_sha}"
t_assert_fails test -e "${w}/d4/model.onnx"
t_assert_eq 0 "$(find "${w}/cache" -name '.part*' | wc -l | tr -d ' ')"

t_case "--only fetches the named file, and a name the lock lacks fails"
t_assert_ok fetch --lock "${w}/models.lock" --dest "${w}/d5" --only model.LICENSE
t_assert_ok test -f "${w}/d5/model.LICENSE"
t_assert_fails test -e "${w}/d5/model.onnx"
t_assert_fails fetch --lock "${w}/models.lock" --dest "${w}/d5" --only nope.onnx
t_assert_contains "$(log)" "nope.onnx not in"

# refused <message> <lock line>: a lock holding that line fails and names why.
refused() {
  printf '%s\n' "$2" > "${w}/bad.lock"
  t_assert_fails fetch --lock "${w}/bad.lock" --dest "${w}/d6"
  t_assert_contains "$(log)" "$1"
}
t_case "a malformed lock fails on its line; a missing lock is a usage error"
refused "expected 'sha256 file url'" "${model_sha} model.onnx"
refused "is no sha256" "abc model.onnx file://${rel}/model.onnx"
refused "is not a plain file name" "${model_sha} ../model.onnx file://${rel}/model.onnx"
refused "a second line for model.onnx" "$(line model.onnx)
$(line model.onnx)"
refused "only https, http and file URLs" "$(line model.onnx "ftp://127.0.0.1:9/model.onnx")"
refused "offline, put the file at ${w}/cache/${model_sha}-model.onnx" "$(line model.onnx "file://${w}/nowhere/model.onnx")"
t_assert_eq 2 "$(t_rc "${PY}" -I "${FETCH}" --lock "${w}/no.lock")"

t_case "the cache is KATAGLYPHIS_MODEL_CACHE, or KATAGLYPHIS_ASSET_CACHE with --extract"
t_assert_ok env KATAGLYPHIS_MODEL_CACHE="${w}/model-cache" "${PY}" -I "${FETCH}" --lock "${w}/models.lock" --dest "${w}/d7"
t_assert_ok test -f "${w}/model-cache/${model_sha}-model.onnx"
t_assert_ok env KATAGLYPHIS_ASSET_CACHE="${w}/asset-cache" "${PY}" -I "${FETCH}" --lock "${w}/assets.lock" --dest "${w}/m0" --extract --only scene
t_assert_ok test -f "${w}/asset-cache/$(sha "${rel}/scene.tar.xz")-scene.tar.xz"

t_case "--extract unpacks <name>/ with a stamp of its sha256 and file count, its files newer than the archive's"
t_assert_ok fetch --lock "${w}/assets.lock" --dest "${w}/m1" --extract --only scene
t_assert_eq a "$(cat "${w}/m1/scene/a.txt" 2>&1)"
t_assert_eq "$(sha "${rel}/scene.tar.xz") 2" "$(cat "${w}/m1/scene/.assetant-sha256" 2>&1)"
t_assert_ok test "$(stat -c %Y "${w}/m1/scene/sub/b.txt")" -gt 1000000000
t_assert_eq 0 "$(find "${w}/m1" -maxdepth 1 -name '.scene.*' | wc -l | tr -d ' ')"

t_case "an up-to-date scene is left alone; a file gone under its stamp, or a stale stamp, brings it back"
t_assert_ok fetch --lock "${w}/assets.lock" --dest "${w}/m1" --extract --only scene
t_assert_eq "" "$(log)"
rm "${w}/m1/scene/sub/b.txt"
t_assert_ok fetch --lock "${w}/assets.lock" --dest "${w}/m1" --extract --only scene
t_assert_eq b "$(cat "${w}/m1/scene/sub/b.txt" 2>&1)"
printf 'feed 2\n' > "${w}/m1/scene/.assetant-sha256"
t_assert_ok fetch --lock "${w}/assets.lock" --dest "${w}/m1" --extract --only scene
t_assert_contains "$(log)" "fetched ${w}/m1/scene"

t_case "a scene directory without a stamp is not this fetcher's to replace"
mkdir -p "${w}/m2/scene"
printf 'mine' > "${w}/m2/scene/keep.txt"
t_assert_fails fetch --lock "${w}/assets.lock" --dest "${w}/m2" --extract --only scene
t_assert_contains "$(log)" "exists but was not fetched"
t_assert_eq mine "$(cat "${w}/m2/scene/keep.txt" 2>&1)"

t_case "an archive with anything outside <name>/, or a file that is no archive, fails and writes nothing"
t_assert_fails fetch --lock "${w}/assets.lock" --dest "${w}/m3" --extract --only bad
t_assert_contains "$(log)" "outside the bad/"
t_assert_eq 0 "$(find "${w}/m3" -mindepth 1 | wc -l | tr -d ' ')"
t_assert_fails fetch --lock "${w}/models.lock" --dest "${w}/m3" --extract
t_assert_contains "$(log)" "model.onnx is no .tar.xz"

t_case "kataglyphis_fetch_data in cmake -P fetches, and a failed fetch stops cmake"
t_needs cmake command -v cmake
# cmake_fetch <lock> <dest>: the module's function, run as a cmake script with a cache of its own.
cmake_fetch() {
  printf 'list(APPEND CMAKE_MODULE_PATH "%s")\ninclude(KataglyphisFetchData)\nkataglyphis_fetch_data(LOCK "%s" DEST "%s" EXTRACT ONLY scene)\n' \
    "${CMAKE_MODULES}" "$1" "$2" > "${w}/fetch.cmake"
  KATAGLYPHIS_ASSET_CACHE="${w}/cmake-cache-$(basename "$2")" cmake -P "${w}/fetch.cmake" > "${w}/log" 2>&1
}
t_assert_ok cmake_fetch "${w}/assets.lock" "${w}/m4"
t_assert_ok test -f "${w}/m4/scene/.assetant-sha256"
line scene.tar.xz "file://${w}/nowhere/scene.tar.xz" > "${w}/gone.lock"
t_assert_fails cmake_fetch "${w}/gone.lock" "${w}/m5"
t_assert_contains "$(log)" "was not fetched"

t_summary
