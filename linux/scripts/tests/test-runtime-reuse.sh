#!/usr/bin/env bash
# A failed arch re-runs alone; registry and builds stubbed. docs/linux-cross-builds.md#a-failed-arch-re-runs-alone
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
LIB="${SCRIPTS}/lib-runtime-reuse.sh"
KEY_PY="${SCRIPTS}/runtime-build-key.py"
MANIFEST="${SCRIPTS}/build-runtime-manifest.sh"
FRESHNESS="${SCRIPTS}/verify-manifest-freshness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- the closure helper --------------------------------------------------------
ctx="${WORK}/ctx"
mkdir -p "${ctx}/linux/scripts/core/__pycache__" "${ctx}/linux/unused"
printf 'a\n' > "${ctx}/linux/scripts/bound.sh"
printf 'b\n' > "${ctx}/linux/scripts/core/lib.sh"
# Python's atomic write leaves lib.cpython-314.pyc.<n> beside the .pyc; .dockerignore drops both, and *.pyc anywhere.
printf 'junk\n' > "${ctx}/linux/scripts/core/__pycache__/lib.cpython-314.pyc.140234"
printf 'junk\n' > "${ctx}/linux/scripts/core/stray.pyc"
printf 'c\n' > "${ctx}/linux/unused/other.sh"
printf 'v=1\n' > "${ctx}/pins.env"
cat > "${ctx}/Dockerfile" <<'EOF'
FROM scratch AS other
# COPY linux/unused/other.sh /never
RUN --mount=type=bind,source=linux/scripts/bound.sh,target=/b.sh \
    --mount=type=cache,target=/var/cache/apt \
    --mount=type=bind,from=other,source=/out,target=/o \
    true
COPY --chmod=755 linux/scripts/core/ /opt/core/
COPY --link --from=other /opt/x /opt/x
EOF
_key() { python3 "${KEY_PY}" --root "${ctx}" --dockerfile Dockerfile --extra pins.env "$@"; }

t_case "the closure lists the Dockerfile, its binds, its copies and the extras, nothing else"
listing="$(_key --list)"
t_assert_contains "${listing}" "file Dockerfile "
t_assert_contains "${listing}" "file linux/scripts/bound.sh "
t_assert_contains "${listing}" "file linux/scripts/core/lib.sh "
t_assert_contains "${listing}" "file pins.env "
t_assert_eq "4" "$(printf '%s\n' "${listing}" | wc -l)" "a --from source, a comment or __pycache__ widened the closure"

t_case "an edit inside the closure changes the key, an edit outside it does not"
k0="$(_key)"
t_assert_eq 64 "${#k0}"
printf 'c2\n' > "${ctx}/linux/unused/other.sh"
t_assert_eq "${k0}" "$(_key)" "a file no runtime Dockerfile reads must not block reuse"
printf 'b2\n' > "${ctx}/linux/scripts/core/lib.sh"
k1="$(_key)"
t_assert_ok test "${k0}" != "${k1}"
chmod +x "${ctx}/linux/scripts/bound.sh"
t_assert_ok test "${k1}" != "$(_key)"

t_case "an input the helper cannot pin down fails closed"
cp "${ctx}/Dockerfile" "${ctx}/Dockerfile.good"
printf 'COPY ${SRC} /x\n' >> "${ctx}/Dockerfile"
t_assert_rc 1 _key
cp "${ctx}/Dockerfile.good" "${ctx}/Dockerfile"
printf 'RUN --mount=type=bind,target=/ctx true\n' >> "${ctx}/Dockerfile"
t_assert_rc 1 _key
cp "${ctx}/Dockerfile.good" "${ctx}/Dockerfile"
printf 'COPY linux/missing.sh /x\n' >> "${ctx}/Dockerfile"
t_assert_rc 1 _key
cp "${ctx}/Dockerfile.good" "${ctx}/Dockerfile"
printf 'COPY ../outside /x\n' >> "${ctx}/Dockerfile"
t_assert_rc 1 _key
cp "${ctx}/Dockerfile.good" "${ctx}/Dockerfile"

t_case "the real runtime Dockerfiles resolve to a key"
t_assert_rc 0 python3 "${KEY_PY}" --root "${SCRIPTS}/../.." --dockerfile linux/Dockerfile.base \
  --dockerfile linux/Dockerfile.package --dockerfile linux/Dockerfile.torch \
  --extra linux/scripts/01-core/versions.env --extra linux/scripts/01-core/tool-pins.env

# _lib <body>: the library with its collaborators stubbed; REC_<arch> holds "<run-id> <build-key>", PIN_<arch> the android ref.
_lib() {
  (
    set +e
    REPO_ROOT="${ctx}" BASE_DOCKERFILE_PATH=Dockerfile PACKAGE_DOCKERFILE_PATH=Dockerfile WRAPPER_DOCKERFILE_PATH=Dockerfile
    mkdir -p "${ctx}/linux/scripts/01-core"
    : > "${ctx}/linux/scripts/01-core/versions.env"; : > "${ctx}/linux/scripts/01-core/tool-pins.env"
    # shellcheck source=linux/scripts/lib-runtime-reuse.sh
    source "${LIB}"
    warn() { printf 'WARN %s\n' "$*"; }
    log()  { printf 'LOG %s\n' "$*"; }
    run()  { printf 'RUN %s\n' "$*"; [ "${RUN_FAILS:-0}" = 0 ]; }
    runtime_wrapper_tag() { printf 'img:latest-%s' "$1"; }
    runtime_android_pin() { local v="PIN_$1"; printf '%s' "${!v:-}"; }
    append_version_build_args() { local -n _o="$1"; _o+=(--build-arg "STUB_VERSION=${STUB_VERSION}"); }
    _rec() { local a="${1##*-}" v; v="REC_${a}"; printf '%s' "${!v:-}"; }
    ancestry_recorded_run_id() { local r; r="$(_rec "$1")"; [ -n "${r}" ] || return 2; printf '%s' "${r%% *}"; }
    ancestry_recorded_provenance() { local r; r="$(_rec "$1")"; [ -n "${r#* }" ] && [ "${r#* }" != "${r}" ] || return 2; printf '%s' "${r#* }"; }
    registry_pin_ref() { local a="${2##*-}" v; v="DIG_${a}"; [ -n "${!v:-}" ] || return 1; printf 'img@%s' "${!v}"; }
    eval "$1"
  ) 2>&1
}
export STUB_VERSION=1 PIN_amd64="repo/android@sha256:aaa" PIN_arm64="repo/android@sha256:bbb" PIN_riscv64="repo/android@sha256:ccc"

t_case "an arch's key changes with its android parent, its version args and the knobs, not with the repo prefix"
base="$(_lib 'runtime_build_key amd64')"
t_assert_eq 64 "${#base}" "the key fixture must produce a key, or every comparison below proves nothing"
t_assert_eq "${base}" "$(PIN_amd64="other/repo@sha256:aaa" _lib 'runtime_build_key amd64')"
t_assert_ok test "${base}" != "$(PIN_amd64="repo/android@sha256:ddd" _lib 'runtime_build_key amd64')"
t_assert_ok test "${base}" != "$(STUB_VERSION=2 _lib 'runtime_build_key amd64')"
t_assert_ok test "${base}" != "$(APP_REF=deadbeef _lib 'runtime_build_key amd64')"
t_assert_ok test "${base}" != "$(_lib 'runtime_build_key arm64')"

t_case "no android digest means no key, so that arch is never reused"
t_assert_contains "$(PIN_amd64="repo/android:tag" _lib 'runtime_build_key amd64; echo "RC=$?"')" "RC=1"
out="$(PIN_amd64="" _lib 'runtime_build_keys_export amd64; echo "SET=${RUNTIME_BUILD_KEY_amd64-unset}"')"
t_assert_contains "${out}" "SET=unset"
t_assert_contains "${out}" "cannot be reused"

t_case "a mistyped RUNTIME_REUSE_CHILDREN stops the lane"
t_assert_contains "$(RUNTIME_REUSE_CHILDREN=yes _lib 'runtime_reuse_mode; echo "RC=$?"')" "RC=2"
t_assert_eq "on" "$(_lib 'runtime_reuse_mode')"

# --- the plan --------------------------------------------------------------------
fake_nerdctl="${WORK}/nerdctl"
cat > "${fake_nerdctl}" <<'SH'
#!/usr/bin/env bash
case "${PUBLISHED:-}" in
  none) echo "manifest unknown" >&2; exit 1 ;;
  broken) echo "denied: token expired" >&2; exit 1 ;;
esac
for a in ${PUBLISHED}; do printf '{"platform": {"architecture": "%s"}}\n' "${a}"; done
SH
chmod +x "${fake_nerdctl}"
export NERDCTL_BIN="${fake_nerdctl}"
# Keys as runtime_build_key computes them, so the "built earlier from the same inputs" record is real.
k_amd64="$(_lib 'runtime_build_key amd64')"
k_arm64="$(_lib 'runtime_build_key arm64')"
export PUBLISHED="amd64 arm64 riscv64" CROSS_RUN_ID=run-new DIG_amd64=sha256:a1 DIG_arm64=sha256:b1
export REC_amd64="run-old ${k_amd64}" REC_arm64="run-old not-this-key"
_plan() { _lib 'runtime_reuse_plan img:latest riscv64; printf "INDEX=%s\n" "${RUNTIME_INDEX_ARCHES}"; printf "REUSED=%s\n" "${RUNTIME_REUSED_REFS}"; '"${1:-}"; }

t_case "a riscv64-only run keeps the published child built from the same inputs, pinned by digest"
out="$(_plan)"
t_assert_contains "${out}" "INDEX=riscv64,amd64"
t_assert_contains "${out}" "REUSED=amd64 img@sha256:a1"
t_assert_contains "${out}" "reusing img@sha256:a1, built by run run-old"

t_case "a child whose build key differs is not reused, and the warning says how to rebuild it"
t_assert_contains "${out}" "img:latest-arm64 is stale"
t_assert_contains "${out}" "add arm64 to --target-arches"
t_assert_eq "0" "$(printf '%s\n' "${out}" | grep -c -e 'arm64 img@' || true)"

t_case "RUNTIME_REUSE_CHILDREN=0 restores the strict index: only this run's arches"
t_assert_contains "$(RUNTIME_REUSE_CHILDREN=0 _plan)" "INDEX=riscv64
REUSED="

t_case "nothing published, or an unreadable index, reuses nothing"
t_assert_contains "$(PUBLISHED=none _plan)" "INDEX=riscv64
REUSED="
out="$(PUBLISHED=broken _plan)"
t_assert_contains "${out}" "INDEX=riscv64"
t_assert_contains "${out}" "could not read img:latest"

t_case "a reusable child without a registry digest is not reused"
t_assert_contains "$(DIG_amd64="" _plan)" "INDEX=riscv64
REUSED="

t_case "the pull re-reads each reused child by digest under its wrapper tag, and a failed pull fails"
out="$(_plan 'runtime_reuse_pull; echo "PULL=$?"')"
t_assert_contains "${out}" "RUN ${fake_nerdctl} pull -q --platform linux/amd64 img@sha256:a1"
t_assert_contains "${out}" "RUN ${fake_nerdctl} tag img@sha256:a1 img:latest-amd64"
t_assert_contains "${out}" "PULL=0"
t_assert_contains "$(RUN_FAILS=1 _plan 'runtime_reuse_pull; echo "PULL=$?"')" "PULL=1"

t_case "the recheck refuses a reused child that moved or stopped matching"
t_assert_contains "$(_plan 'runtime_reuse_recheck; echo "RECHECK=$?"')" "RECHECK=0"
t_assert_contains "$(_plan 'DIG_amd64=sha256:a2 runtime_reuse_recheck; echo "RECHECK=$?"')" "RECHECK=1"
t_assert_contains "$(_plan 'REC_amd64="run-old other" runtime_reuse_recheck; echo "RECHECK=$?"')" "RECHECK=1"

# --- the manifest lane ------------------------------------------------------------
_manifest_fns=""
for fn in _manifest_completeness_gate _manifest_index_refs create_manifest _manifest_each_arch _manifest_gate_jobs _manifest_build_and_smoke _manifest_plan_reuse; do
  _manifest_fns+="$(t_fn_src "${MANIFEST}" "${fn}")"$'\n' || exit 1
done
# _lane <body>: the manifest functions over the plan above; gates, binfmt and the build loop are recorders.
_lane() {
  _lib '
    eval "${_MANIFEST_FNS}"
    arch_list_to_words() { printf "%s\n" ${1//,/ }; }
    IMAGE_NAME=img:latest TARGET_ARCHES=riscv64 BUILD_IMAGES=1 CREATE_MANIFEST=1 PUSH_MANIFEST=0 FORCE_MANIFEST=0 RUNTIME_IMAGE_SMOKE=1 MAX_PARALLEL_ARCHS=1
    is_dry_run() { return 1; }
    err() { printf "ERR %s\n" "$*"; exit 1; }
    ensure_foreign_binfmt() { printf "BINFMT %s\n" "$1"; }
    runtime_input_preflight() { :; }
    runtime_push_queue_start() { :; }
    runtime_push_queue_finish() { :; }
    run_parallel_arch_loop() { shift 3; printf "BUILT %s\n" "$*"; }
    arch_loop_flag_prefix() { :; }
    _manifest_gate_arch() { printf "GATE %s %s\n" "$1" "$3"; }
    _manifest_image_env_gate() { printf "ENVGATE\n"; }
    _manifest_wrapper_gate() { printf "COHERENCE\n"; }
    RUNTIME_GATE_JOBS=1
    '"$1"
}
export _MANIFEST_FNS="${_manifest_fns}"

t_case "the lane builds only the failed arch, and gates every child of the index"
out="$(_lane '_manifest_plan_reuse; _manifest_build_and_smoke')"
t_assert_contains "${out}" "BUILT riscv64"
t_assert_eq "0" "$(printf '%s\n' "${out}" | grep -c -e 'BUILT.*amd64' || true)" "a reused arch was rebuilt"
t_assert_contains "${out}" "BINFMT riscv64,amd64"
t_assert_contains "${out}" "GATE Wrapper content gate riscv64"
t_assert_contains "${out}" "GATE Wrapper content gate amd64"
t_assert_contains "${out}" "GATE Runtime-image smoke amd64"
pull_line="$(printf '%s\n' "${out}" | grep -n -e 'pull -q' | head -1 | cut -d: -f1)"
gate_line="$(printf '%s\n' "${out}" | grep -n -e 'GATE Wrapper content gate amd64' | head -1 | cut -d: -f1)"
t_assert_ok test "${pull_line:-999}" -lt "${gate_line:-0}"

t_case "the index lists the reused children by digest and passes the completeness gate"
out="$(REC_arm64="run-old ${k_arm64}" _lane '_manifest_plan_reuse; create_manifest')"
t_assert_contains "${out}" "manifest create img:latest img:latest-riscv64 img@sha256:a1 img@sha256:b1"
t_assert_eq "0" "$(printf '%s\n' "${out}" | grep -c -e '^ERR' || true)" "${out}"

t_case "without reuse the same run is refused rather than shrinking the index"
out="$(RUNTIME_REUSE_CHILDREN=0 _lane '_manifest_plan_reuse; create_manifest')"
t_assert_contains "${out}" "pushing it would DROP: amd64 arm64"
t_assert_contains "${out}" "ERR manifest completeness gate refused"

t_case "a child that is not reusable still blocks the index: arm64 is dropped, so the gate refuses"
t_assert_contains "$(_lane '_manifest_plan_reuse; create_manifest')" "would DROP: arm64"

t_case "a reused child that moved after its gates refuses the index"
out="$(_lane '_manifest_plan_reuse; DIG_amd64=sha256:a2; create_manifest')"
t_assert_contains "${out}" "ERR manifest reuse gate refused"

t_case "a --manifest-only repair and a dry run never complete an index from older children"
t_assert_contains "$(_lane 'BUILD_IMAGES=0; _manifest_plan_reuse; echo "INDEX=${RUNTIME_INDEX_ARCHES} REUSED=${RUNTIME_REUSED_REFS}"')" "INDEX=riscv64 REUSED="
t_assert_contains "$(_lane 'is_dry_run() { return 0; }; _manifest_plan_reuse; echo "INDEX=${RUNTIME_INDEX_ARCHES} REUSED=${RUNTIME_REUSED_REFS}"')" "INDEX=riscv64 REUSED="

t_case "the wrapper build stamps the arch's own key, and nothing when the orchestrator computed none"
_label() { _lib 'a=(); runtime_build_key_label_args a '"$1"'; printf "ARGS=%s\n" "${a[*]}"'; }
t_assert_contains "$(RUNTIME_BUILD_KEY_arm64=k9 _label arm64)" "ARGS=--label org.kataglyphis.build-key=k9"
t_assert_eq "ARGS=" "$(RUNTIME_BUILD_KEY_arm64=k9 _label amd64 | tail -1)"
wrapper_src="$(t_fn_src "${SCRIPTS}/01-core/runtime-build-fns.sh" _runtime_build_wrapper)" || exit 1
t_assert_contains "${wrapper_src}" 'runtime_build_key_label_args _wrap_out "${arch}"'

# --- the freshness check ------------------------------------------------------------
fake_bin="${WORK}/bin"
mkdir -p "${fake_bin}"
cat > "${fake_bin}/curl" <<'SH'
#!/usr/bin/env bash
url="${*: -1}"
case "${url}" in
  *ghcr.io/token*) printf '{"token": "t"}' ;;
  */manifests/latest) printf '{"manifests": [{"digest": "sha256:A", "platform": {"os": "linux", "architecture": "amd64"}}, {"digest": "sha256:R", "platform": {"os": "linux", "architecture": "riscv64"}}]}' ;;
  */manifests/latest-amd64) printf 'docker-content-digest: sha256:A\r\n' ;;
  */manifests/latest-riscv64) printf 'docker-content-digest: sha256:R\r\n' ;;
  */manifests/sha256:A) printf '{"config": {"digest": "sha256:cA"}}' ;;
  */manifests/sha256:R) printf '{"config": {"digest": "sha256:cR"}}' ;;
  */blobs/sha256:cA) printf '{"config": {"Labels": {"org.kataglyphis.run-id": "run-old", "org.kataglyphis.build-key": "%s"}}}' "${FAKE_KEY_A}" ;;
  */blobs/sha256:cR) printf '{"config": {"Labels": {"org.kataglyphis.run-id": "run-new", "org.kataglyphis.build-key": "kR"}}}' ;;
  *) exit 22 ;;
esac
SH
chmod +x "${fake_bin}/curl"
_fresh() { FAKE_KEY_A="${1:-kA}" PATH="${fake_bin}:${PATH}" EXPECT_RUN_ID=run-new bash "${FRESHNESS}" --tag latest 2>&1; }

t_case "freshness passes a reused child carrying this run's build key beside a child of this run"
out="$(EXPECT_REUSED="amd64:kA" _fresh)"
t_assert_contains "${out}" "amd64: reused child carries this run's build key"
t_assert_contains "${out}" "all 1 built children share run-id run-new"
t_assert_contains "${out}" "PASS"

t_case "freshness fails a reused child with another key, and an unexpected older child"
t_assert_contains "$(EXPECT_REUSED="amd64:kA" _fresh kX)" "reused child's build key is kX, expected kA"
t_assert_contains "$(_fresh)" "children disagree on run-id"

t_summary
