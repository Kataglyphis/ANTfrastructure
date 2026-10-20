#!/usr/bin/env bash
# build|verify: a uv cache holding the wheels an app's lock must build from source on this arch. docs/consumer-image-contract.md#the-riscv64-uv-cache-seed
set -euo pipefail

say() { printf '[uv-cache-seed] %s\n' "$*"; }
die() { printf '[uv-cache-seed] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  uv-cache-seed.sh build (--app-dir DIR | --app-url URL --app-ref COMMIT) --out DIR --work-cache DIR
                        [--extras LIST] [--python VER] [--arches LIST]
  uv-cache-seed.sh verify SEED [ARCH]

build   syncs the app's committed lock (--locked --dev, the extras, no project) through
        --work-cache on X.Y and on its free-threaded X.Yt, copies the wheels uv built from
        source into --out, and proves a fresh copy of --out syncs the same lock on both without
        building. An arch outside --arches (default riscv64) gets a record that says so and no cache.
verify  checks a seed's record: its arch, a GIL and a free-threaded pass, each one's proof, and
        every listed wheel in the cache.
EOF
}

SEED_RECORD="seed-record.txt"

# <request>: the venv interpreters a seed covers, the GIL build and its free-threaded twin.
seed_requests() { printf '%s+gil\n%st\n' "$1" "$1"; }

# <venv>: X.Y.Z, with a t for a free-threaded build.
venv_python() {
  "$1/bin/python" -c 'import platform, sysconfig; print(platform.python_version() + ("t" if sysconfig.get_config_var("Py_GIL_DISABLED") else ""))'
}

# <request> <dir>: a venv on the image's interpreter, refused when uv hands over the other build.
seed_venv() {
  local request="$1" dir="$2" got
  # The image ships both builds; a download would seed for an interpreter no lane runs.
  UV_PYTHON_DOWNLOADS=never uv venv -q --python "${request}" "${dir}" || die "no ${request} interpreter for the seed"
  got="$(venv_python "${dir}")" || die "the ${request} venv's python does not run"
  case "${request}:${got}" in
    *t:*t | *+gil:*[0-9]) printf '%s\n' "${got}" ;;
    *) die "asked uv for ${request}, it gave ${got}" ;;
  esac
}

# The sync ci_tests.sh runs (uv_sync_project), minus the project: its Cython build is not a dependency.
seed_sync() {
  local tree="$1" cache="$2" venv="$3" extras="$4" e
  shift 4
  local -a args=(sync --locked --dev --no-install-project --python "${venv}/bin/python")
  local -a list=()
  IFS=',' read -r -a list <<<"${extras}"
  for e in ${list[@]+"${list[@]}"}; do
    [ -n "${e}" ] && args+=(--extra "${e}")
  done
  (cd "${tree}" && env -u UV_PYTHON -u VIRTUAL_ENV UV_CACHE_DIR="${cache}" \
    UV_PROJECT_ENVIRONMENT="${venv}" uv "${args[@]}" "$@")
}

# One "<name> <version>" per wheel uv built from an sdist, read from its own progress lines.
built_from_log() {
  sed -n 's/^[[:space:]]*Built \([^=[:space:]]*\)==\([^[:space:]]*\).*/\1 \2/p' "$1" | LC_ALL=C sort -u
}

# Every wheel the cache holds that uv built from an sdist, one relative path per line.
built_wheels() {
  (cd "$1" && find . -path './sdists-v*/pypi/*/*/*/*.whl' -print) | LC_ALL=C sort
}

# Every "built <name> <version> <abi>" row of a record names a wheel the cache holds; prints the misses.
record_misses() {
  local seed="$1" name version abi norm whl re hit
  while read -r name version abi; do
    norm="$(printf '%s' "${name}" | tr '[:upper:]_.' '[:lower:]--')"
    # The ABI tag is the wheel name's second-to-last field: cp314 and cp314t share the python tag cp314.
    re="-${abi:-[^-]+}-[^-]+\\.whl\$"
    hit=""
    for whl in "${seed}"/sdists-v*/pypi/"${norm}"/"${version}"/*/*.whl; do
      [[ "${whl##*/}" =~ ${re} ]] && { hit=1; break; }
    done
    [ -n "${hit}" ] || printf '%s==%s%s\n' "${name}" "${version}" "${abi:+ (${abi})}"
  done < <(sed -n 's/^built //p' "${seed}/${SEED_RECORD}")
}

# <tmp> <app-dir> | <tmp> "" <url> <ref>: exports the committed tree to <tmp>/app, prints its commit.
seed_tree() {
  local tmp="$1" app="$2" url="${3:-}" ref="${4:-}" repo rev=HEAD
  repo="${app}"
  if [ -z "${repo}" ]; then
    # The shipped app tree has no .git and a riscv64-edited pyproject, so the seed reads its own fetch.
    repo="${tmp}/app.git"
    rev=FETCH_HEAD
    git init -q --bare "${repo}"
    git -C "${repo}" fetch -q --depth 1 "${url}" "${ref}" || die "cannot fetch ${ref} from ${url}"
  fi
  mkdir -p "${tmp}/app"
  # The committed tree, whatever a working copy says: --locked refuses a lock its pyproject no longer matches.
  git -C "${repo}" archive --format=tar "${rev}" | tar -x -C "${tmp}/app" -f - || die "cannot export ${rev} of ${repo}"
  [ -f "${tmp}/app/uv.lock" ] || die "the app has no uv.lock to seed from"
  git -C "${repo}" rev-parse "${rev}"
}

# <work> <out> <venv>...: the work cache's built wheels for what the venvs hold, without downloads or sources.
seed_copy() {
  local work="$1" out="$2" keep="" dir name version venv
  shift 2
  cp -a "${work}/." "${out}/"
  uv cache prune --ci --cache-dir "${out}" >/dev/null || die "uv cache prune --ci failed on ${out}"
  rm -rf "${out}/interpreter-v"* "${out}/builds-v"*
  # The work cache keeps every version it ever built; the seed keeps only what these syncs installed.
  for venv in "$@"; do
    keep+="$(uv pip list --python "${venv}/bin/python" --format freeze \
      | awk -F'==' 'NF == 2 { n = tolower($1); gsub(/[_.]/, "-", n); print n, $2 }')"$'\n'
  done
  [ -n "${keep//$'\n'/}" ] || die "the seed venvs list no installed distribution"
  for dir in "${out}"/sdists-v*/pypi/*/*/; do
    [ -d "${dir}" ] || continue
    version="$(basename "${dir}")"
    name="$(basename "$(dirname "${dir}")")"
    grep -qxF -e "${name} ${version}" <<<"${keep}" || rm -rf "${dir}"
  done
  find "${out}" -depth -type d -empty -delete
}

# <out> <tmp> <python> <extras>: one fresh copy syncs the lock into a fresh venv per interpreter and builds nothing.
seed_prove() {
  local out="$1" tmp="$2" python="$3" extras="$4" cache="$2/proof-cache" request i=0 got
  local -a requests=()
  mapfile -t requests < <(seed_requests "${python}")
  cp -a "${out}" "${cache}"
  rm -f "${cache}/${SEED_RECORD}"
  for request in "${requests[@]}"; do
    i=$((i + 1))
    built_wheels "${cache}" > "${tmp}/before.txt"
    got="$(seed_venv "${request}" "${tmp}/.venv-proof-${i}")" || exit 1
    seed_sync "${tmp}/app" "${cache}" "${tmp}/.venv-proof-${i}" "${extras}" 2>&1 | tee "${tmp}/proof-${i}.log" \
      || die "a fresh copy of the seed does not sync the lock on ${got}"
    built_wheels "${cache}" > "${tmp}/after.txt"
    # --no-build cannot say it: it refuses every sdist, cached or not.
    if grep -qE '^[[:space:]]*(Building|Built) ' "${tmp}/proof-${i}.log" || ! cmp -s "${tmp}/before.txt" "${tmp}/after.txt"; then
      die "the seed does not cover the lock on ${got}, the proof sync built: $(built_from_log "${tmp}/proof-${i}.log" | tr '\n' ' ')$(LC_ALL=C comm -13 "${tmp}/before.txt" "${tmp}/after.txt" | tr '\n' ' ')"
    fi
    printf 'proof %s a fresh copy synced the lock and built nothing: ok\n' "${got}" >> "${tmp}/proofs.txt"
  done
}

# Sets APP URL REF OUT WORK EXTRAS PY ARCHES from build's flags.
parse_build_args() {
  APP="" URL="" REF="" OUT="" WORK="" EXTRAS="test" PY="${PYTHON_MAJOR_MINOR:-}" ARCHES="riscv64"
  local -A flag=([--app-dir]=APP [--app-url]=URL [--app-ref]=REF [--out]=OUT [--work-cache]=WORK
    [--extras]=EXTRAS [--python]=PY [--arches]=ARCHES)
  while [ "$#" -gt 1 ]; do
    [ -n "${flag[$1]:-}" ] || die "build: unknown argument '$1'"
    printf -v "${flag[$1]}" '%s' "$2"
    shift 2
  done
  [ "$#" -eq 0 ] || die "build: '$1' takes a value"
  [ -n "${OUT}" ] && [ -n "${WORK}" ] && { [ -n "${APP}" ] || { [ -n "${URL}" ] && [ -n "${REF}" ]; }; } \
    || { usage >&2; exit 2; }
}

cmd_build() {
  parse_build_args "$@"
  local app="${APP}" out="${OUT}" work="${WORK}" extras="${EXTRAS}" python="${PY}" arches="${ARCHES}" arch tmp commit built
  local request got i=0
  local -a requests=() venvs=()
  # The image's own X.Y by default, so a Python upgrade reseeds for the new interpreter.
  [ -n "${python}" ] || die "build: no --python, and no PYTHON_MAJOR_MINOR in the environment"
  arch="$(uname -m)"
  rm -rf "${out}"
  mkdir -p "${out}" "${work}"
  if [[ ",${arches}," != *",${arch},"* ]]; then
    printf 'arch %s\nseeded no: only %s is seeded, PyPI publishes the other arches their wheels\n' \
      "${arch}" "${arches}" > "${out}/${SEED_RECORD}"
    say "${arch} is not in ${arches}: recorded, nothing seeded"
    return 0
  fi
  command -v uv >/dev/null 2>&1 || die "uv is not on PATH"
  tmp="$(mktemp -d)"
  commit="$(seed_tree "${tmp}" "${app}" "${URL}" "${REF}")"
  mapfile -t requests < <(seed_requests "${python}")

  printf 'arch %s\napp %s\nextras %s\nuv %s\n' "${arch}" "${commit}" "${extras}" "$(uv --version | awk '{print $2}')" \
    > "${tmp}/record-head.txt"
  # One work cache for both passes: a pure-Python sdist built on the first serves the second.
  for request in "${requests[@]}"; do
    i=$((i + 1))
    got="$(seed_venv "${request}" "${tmp}/.venv-work-${i}")" || exit 1
    say "syncing the app @ ${commit} (extras: ${extras}) on ${got} through ${work}"
    seed_sync "${tmp}/app" "${work}" "${tmp}/.venv-work-${i}" "${extras}" 2>&1 | tee -a "${tmp}/work.log" \
      || die "the seed sync on ${got} failed; see the output above"
    venvs+=("${tmp}/.venv-work-${i}")
    printf 'python %s\n' "${got}" >> "${tmp}/record-head.txt"
  done
  seed_copy "${work}" "${out}" "${venvs[@]}"
  { cat "${tmp}/record-head.txt"; printf 'seeded yes\n'; } > "${out}/${SEED_RECORD}"
  # A warm work cache prints no Built line, so the record lists the wheels the seed holds, by ABI tag.
  built_wheels "${out}" | sed -n 's|.*/\([^/-]*\)-\([^/-]*\)-.*-\([^/-]*\)-[^/-]*\.whl$|built \1 \2 \3|p' \
    | LC_ALL=C sort -u >> "${out}/${SEED_RECORD}"
  built="$(built_from_log "${tmp}/work.log" | tr '\n' ' ')"
  say "built this run: ${built:-nothing, the work cache held every wheel}"

  say "proving the seed: a fresh copy syncs on each interpreter without building"
  seed_prove "${out}" "${tmp}" "${python}" "${extras}"
  cat "${tmp}/proofs.txt" >> "${out}/${SEED_RECORD}"
  chmod -R a+rX "${out}"
  rm -rf "${tmp}"
  say "seed ready: $(du -sh "${out}" | cut -f1), $(grep -c '^built ' "${out}/${SEED_RECORD}" || true) wheel(s) built from source"
}

# <seed> [arch]: 0 for a proved seed of the arch, or a record that says it is not seeded.
cmd_verify() {
  local seed="${1:-}" arch="${2:-}" record misses pythons python
  [ -n "${seed}" ] || { usage >&2; exit 2; }
  [ -n "${arch}" ] || arch="$(uname -m)"
  record="${seed}/${SEED_RECORD}"
  [ -f "${record}" ] || die "no ${record}"
  grep -qxF -e "arch ${arch}" "${record}" || die "the record is not ${arch}'s: $(head -1 "${record}")"
  if ! grep -qxF 'seeded yes' "${record}"; then
    say "not seeded: $(sed -n 's/^seeded no: //p' "${record}")"
    return 0
  fi
  pythons="$(sed -n 's/^python //p' "${record}" | tr '\n' ' ')"
  grep -q '^python .*[0-9]$' "${record}" || die "the record has no GIL pass: python ${pythons:-none}"
  grep -q '^python .*t$' "${record}" || die "the record has no free-threaded pass: python ${pythons:-none}"
  for python in ${pythons}; do
    awk -v p="${python}" '$1 == "proof" && $2 == p && /: ok$/ { f = 1 } END { exit !f }' "${record}" \
      || die "the record carries no passed proof for ${python}"
  done
  grep -q '^built ' "${record}" || die "seeded, yet the record lists no wheel built from source"
  misses="$(record_misses "${seed}")"
  [ -z "${misses}" ] || die "the record lists wheels the cache lacks: $(printf '%s' "${misses}" | tr '\n' ' ')"
  say "seeded for ${arch}: $(grep -c '^built ' "${record}") wheel(s) for Python ${pythons% }, proved"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
