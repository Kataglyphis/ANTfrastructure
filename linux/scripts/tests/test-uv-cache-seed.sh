#!/usr/bin/env bash
# The riscv64 uv cache seed: what the build keeps, its proof, the record verify reads, and the consumer's restore; see docs/consumer-image-contract.md#the-riscv64-uv-cache-seed
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
SEED="${SCRIPTS}/06-packaging/uv-cache-seed.sh"
CI_COMMON="${SCRIPTS}/02-toolchain/python/ci-common.sh"
TORCH="${SCRIPTS}/../Dockerfile.torch"
ARCH="$(uname -m)"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/bin"

# A uv that models what the seed relies on: sdists build into sdists-v9 (printing Built), wheels download into wheels-v6.
cat > "${_work}/bin/uv" <<'UV'
#!/usr/bin/env bash
set -eu
case "$1" in
  --version) echo "uv 0.12.23"; exit 0 ;;
  venv)
    for a in "$@"; do d="$a"; done
    mkdir -p "$d/bin"
    printf '#!/bin/sh\necho 3.14.4\n' > "$d/bin/python"; chmod +x "$d/bin/python"
    : > "$d/installed.txt"; exit 0 ;;
  cache)
    case "$2" in
      dir) echo "${UV_CACHE_DIR}"; exit 0 ;;
      prune)
        dir="${@: -1}"
        rm -rf "${dir}/wheels-v6"; rm -rf "${dir}"/sdists-v9/pypi/*/*/*/src; exit 0 ;;
    esac ;;
  pip)
    venv="$(dirname "$(dirname "$4")")"
    sed 's/ /==/' "${venv}/installed.txt"; exit 0 ;;
  sync)
    [ -z "${FAKE_UV_SYNC_FAIL:-}" ] || { echo "error: resolution failed" >&2; exit 1; }
    cache="${UV_CACHE_DIR}"; venv="${UV_PROJECT_ENVIRONMENT}"
    while read -r name version kind; do
      [ -n "${name}" ] || continue
      if [ "${kind}" = sdist ]; then
        hit="$(ls "${cache}"/sdists-v9/pypi/"${name}"/"${version}"/*/"${name//-/_}-${version}"-*.whl 2>/dev/null | head -1 || true)"
        case "${cache}" in *"${FAKE_UV_FORGET_IN:-/nowhere}"*) hit="" ;; esac
        if [ -z "${hit}" ]; then
          echo "   Building ${name}==${version}"
          d="${cache}/sdists-v9/pypi/${name}/${version}/ID$$"
          mkdir -p "${d}/src"; : > "${d}/src/setup.py"
          : > "${d}/${name//-/_}-${version}-cp314-cp314-linux_riscv64.whl"
          echo "      Built ${name}==${version}"
        fi
      else
        mkdir -p "${cache}/wheels-v6/pypi/${name}"; : > "${cache}/wheels-v6/pypi/${name}/${version}"
      fi
      echo "${name} ${version}" >> "${venv}/installed.txt"
    done < deps.txt
    echo "Installed packages"; exit 0 ;;
esac
echo "fake uv: unhandled $*" >&2; exit 3
UV
chmod +x "${_work}/bin/uv"
export PATH="${_work}/bin:${PATH}"

# <dir>: an app checkout whose committed deps.txt is the lock; the working copy gets an uncommitted edit.
_app() {
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'pyyaml 6.0.3 sdist\nline-profiler 5.0.0 sdist\nsix 1.17.0 wheel\n' > "$1/deps.txt"
  : > "$1/uv.lock"; : > "$1/pyproject.toml"
  t_git_commit "$1"
  printf 'edited 9.9.9 sdist\n' >> "$1/deps.txt"
}
_app "${_work}/app"
_seed() { bash "${SEED}" "$@"; }

t_case "an arch outside --arches gets a record that says so, and no cache"
t_assert_ok _seed build --app-dir "${_work}/app" --out "${_work}/none" --work-cache "${_work}/w0" --arches not-an-arch
t_assert_eq "arch ${ARCH}" "$(head -1 "${_work}/none/seed-record.txt")"
t_assert_contains "$(cat "${_work}/none/seed-record.txt")" "seeded no: only not-an-arch is seeded"
t_assert_eq "seed-record.txt" "$(ls -A "${_work}/none")" "nothing but the record"
t_assert_ok _seed verify "${_work}/none"

t_case "the seed keeps the wheels the lock built from source, from the COMMITTED tree, and proves a fresh copy builds nothing"
mkdir -p "${_work}/w1/sdists-v9/pypi/pyyaml/5.4.1/OLD"; : > "${_work}/w1/sdists-v9/pypi/pyyaml/5.4.1/OLD/pyyaml-5.4.1-cp314-cp314-linux_riscv64.whl"
_out="$(t_out _seed build --app-dir "${_work}/app" --out "${_work}/s1" --work-cache "${_work}/w1" --arches "${ARCH}")"
t_assert_eq 0 "$(t_rc test -f "${_work}/s1/seed-record.txt")" "a record: ${_out}"
_rec="$(cat "${_work}/s1/seed-record.txt")"
t_assert_contains "${_rec}" "seeded yes"
t_assert_contains "${_rec}" "built pyyaml 6.0.3"
t_assert_contains "${_rec}" "built line_profiler 5.0.0"
t_assert_contains "${_rec}" "app $(git -C "${_work}/app" rev-parse HEAD)"
t_assert_contains "${_rec}" "proof a fresh copy synced the lock and built nothing: ok"
t_assert_eq 0 "$(grep -c -e edited -e six <<<"${_rec}")" "neither the uncommitted edit nor a downloaded wheel is in the record"
t_assert_eq "" "$(ls -d "${_work}/s1/wheels-v6" "${_work}"/s1/sdists-v9/pypi/*/*/*/src 2>/dev/null)" "prune --ci dropped the downloads and the unpacked sdists"
# A version the lock no longer names stays in the work cache only.
t_assert_fails test -e "${_work}/s1/sdists-v9/pypi/pyyaml/5.4.1"
t_assert_ok test -e "${_work}/w1/sdists-v9/pypi/pyyaml/5.4.1"
t_assert_contains "${_out}" "built this run: line-profiler 5.0.0 pyyaml 6.0.3"
t_assert_ok _seed verify "${_work}/s1"

t_case "a warm work cache builds nothing, and the record still lists every built wheel it holds"
_out="$(t_out _seed build --app-dir "${_work}/app" --out "${_work}/s2" --work-cache "${_work}/w1" --arches "${ARCH}")"
t_assert_contains "${_out}" "built this run: nothing, the work cache held every wheel"
t_assert_eq 2 "$(grep -c '^built ' "${_work}/s2/seed-record.txt")"

t_case "a proof sync that has to build fails the seed: the copy must cover the lock on its own"
_out="$(t_out env FAKE_UV_FORGET_IN=proof-cache bash "${SEED}" build --app-dir "${_work}/app" --out "${_work}/s3" --work-cache "${_work}/w1" --arches "${ARCH}")"
t_assert_eq 1 "$(t_rc env FAKE_UV_FORGET_IN=proof-cache bash "${SEED}" build --app-dir "${_work}/app" --out "${_work}/s3" --work-cache "${_work}/w1" --arches "${ARCH}")"
t_assert_contains "${_out}" "the seed does not cover the lock, the proof sync built: line-profiler 5.0.0 pyyaml 6.0.3"
t_assert_fails grep -q '^proof' "${_work}/s3/seed-record.txt"
t_assert_fails _seed verify "${_work}/s3"

t_case "a failed seed sync fails the build"
t_assert_eq 1 "$(t_rc env FAKE_UV_SYNC_FAIL=1 bash "${SEED}" build --app-dir "${_work}/app" --out "${_work}/s4" --work-cache "${_work}/w4" --arches "${ARCH}")"

t_case "the app commit can be fetched instead of handed over: the shipped tree has no .git"
_sha="$(git -C "${_work}/app" rev-parse HEAD)"
t_assert_ok _seed build --app-url "file://${_work}/app" --app-ref "${_sha}" --out "${_work}/s5" --work-cache "${_work}/w1" --arches "${ARCH}"
t_assert_contains "$(cat "${_work}/s5/seed-record.txt" 2>/dev/null)" "app ${_sha}"
t_assert_eq 2 "$(t_rc _seed build --out "${_work}/s6" --work-cache "${_work}/w1")" "no app at all is a usage error"

t_case "verify fails a record of another arch, a missing proof, and a listed wheel the cache lacks"
cp -a "${_work}/s1" "${_work}/v1"; rm -rf "${_work}"/v1/sdists-v9/pypi/pyyaml
t_assert_contains "$(t_out _seed verify "${_work}/v1")" "the record lists wheels the cache lacks: pyyaml==6.0.3"
t_assert_contains "$(t_out _seed verify "${_work}/s1" other)" "the record is not other's"
cp -a "${_work}/s1" "${_work}/v2"; sed -i '/^proof /d' "${_work}/v2/seed-record.txt"
t_assert_contains "$(t_out _seed verify "${_work}/v2")" "no passed proof"
cp -a "${_work}/s1" "${_work}/v3"; sed -i '/^built /d' "${_work}/v3/seed-record.txt"
t_assert_contains "$(t_out _seed verify "${_work}/v3")" "lists no wheel built from source"

t_case "the consumer copies a seed of its own arch into uv's cache, and nothing else"
_restore() { bash -c 'source "$1"; uv_cache_seed_restore' _ "${CI_COMMON}"; }
export UV_CACHE_DIR="${_work}/consumer-cache"
_out="$(PYTHON_UV_CACHE_SEED="${_work}/s1" t_out _restore)"
t_assert_contains "${_out}" "uv cache seeded from ${_work}/s1 into ${_work}/consumer-cache: 2 wheel(s)"
t_assert_ok test -f "${_work}/consumer-cache/sdists-v9/pypi/pyyaml/6.0.3/$(ls "${_work}/s1/sdists-v9/pypi/pyyaml/6.0.3")/pyyaml-6.0.3-cp314-cp314-linux_riscv64.whl"
export UV_CACHE_DIR="${_work}/c2"
_out="$(PYTHON_UV_CACHE_SEED="${_work}/none" t_out _restore)"
t_assert_contains "${_out}" "uv cache seed: only not-an-arch is seeded"
t_assert_fails test -e "${_work}/c2"
sed -i "s/^arch .*/arch not-${ARCH}/" "${_work}/v3/seed-record.txt"; printf 'built x 1\n' >> "${_work}/v3/seed-record.txt"
_out="$(PYTHON_UV_CACHE_SEED="${_work}/v3" t_out _restore)"
t_assert_contains "${_out}" "is not-${ARCH}'s, not ${ARCH}'s; not used"
t_assert_fails test -e "${_work}/c2"
t_assert_eq "" "$(PYTHON_UV_CACHE_SEED='' t_out _restore)" "no seed variable, no word"
unset UV_CACHE_DIR

t_case "the torch stage builds the seed on the app commit, after the venv, and advertises it"
_torch="$(cat "${TORCH}")"
t_assert_contains "${_torch}" "uv-cache-seed.sh build --app-url https://github.com/Kataglyphis/OrchestrANT.git"
t_assert_contains "${_torch}" '--app-ref "${APP_REF}"'
t_assert_contains "${_torch}" "id=uv-seed-\${TARGETARCH}"
t_assert_contains "${_torch}" "ENV PYTHON_UV_CACHE_SEED=/opt/uv-cache-seed"
t_assert_contains "$(cat "${SCRIPTS}/02-toolchain/python/ci_tests.sh")" "uv_cache_seed_restore"

t_case "the shipped-image contract row: riscv64 must verify seeded, every other arch must say not seeded (mutation)"
SMOKE="${SCRIPTS}/06-packaging/smoke-runtime-image.sh"
_fns="$(t_fn_src "${SMOKE}" _consumer_contract_fact)
$(t_fn_src "${SMOKE}" _consumer_uv_seed_verdict)" || exit 1
_row() { bash -c "${_fns}"$'\n''_consumer_uv_seed_verdict uv-cache-seed "$1" "$2"' _ "$1" "$2"; }
_ok_rv=$'ENV uv-cache-seed /opt/uv-cache-seed\nFACT uv-cache-seed [uv-cache-seed] seeded for riscv64: 9 wheel(s), proved'
_no_amd=$'ENV uv-cache-seed /opt/uv-cache-seed\nFACT uv-cache-seed [uv-cache-seed] not seeded: only riscv64 is seeded, PyPI publishes the other arches their wheels'
t_assert_eq "OK uv-cache-seed 9 wheel(s), proved" "$(_row "${_ok_rv}" riscv64)"
t_assert_eq "OK uv-cache-seed not seeded on amd64, by its record" "$(_row "${_no_amd}" amd64)"
t_assert_contains "$(_row "${_no_amd}" riscv64)" "BAD uv-cache-seed the riscv64 seed does not verify"
t_assert_contains "$(_row "${_ok_rv}" amd64)" "BAD uv-cache-seed the amd64 record is not a \"not seeded\" one"
t_assert_contains "$(_row "${_ok_rv/\/opt\/uv-cache-seed/}" riscv64)" 'BAD uv-cache-seed PYTHON_UV_CACHE_SEED is "", not /opt/uv-cache-seed'
t_assert_contains "$(_row 'FACT uv-cache-seed [uv-cache-seed] ERROR: no /opt/uv-cache-seed/seed-record.txt' riscv64)" "BAD uv-cache-seed"
t_assert_contains "$(_row 'ENV uv-cache-seed /opt/uv-cache-seed' riscv64)" "NOFACT uv-cache-seed"
t_assert_contains "$(sed -n '/^_CONSUMER_CONTRACT_ROWS=/p' "${SMOKE}")" " uv-cache-seed"
t_assert_contains "$(cat "${SMOKE}")" 'uv-cache-seed.sh verify "${PYTHON_UV_CACHE_SEED:-/nonexistent}"'
t_assert_eq "[uv-cache-seed] seeded for ${ARCH}: 2 wheel(s), proved" "$(_seed verify "${_work}/s1" 2>&1 | tail -1)" "the probe's tail -1 is the line the row reads"

t_summary
