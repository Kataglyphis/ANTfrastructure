#!/usr/bin/env bash
# Parity suite: smoke-common.sh's inline arch-map FALLBACKS must agree with
# the canonical 01-core maps. Every in-image smoke sources smoke-common; when
# the canonical modules are absent it falls back to its bundled maps — this
# file has already produced two silent-skip bugs (see its own comments), and
# nothing asserted fallback/canonical parity until now. Add an arch to
# platform.sh without updating smoke-common and this suite goes red instead
# of the smokes silently returning 1.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

SMOKE_COMMON="${TESTS_DIR}/../06-packaging/smoke-common.sh"
CORE="${TESTS_DIR}/../01-core"

# Run a smoke-common function in a CLEAN bash where the canonical 01-core
# functions do not exist — forcing the fallback branch.
_fallback() {
  bash -c "source '${SMOKE_COMMON}' 2>/dev/null; $1" 2>/dev/null
}

# Canonical values from the real modules in THIS shell.
source "${CORE}/platform.sh"
source "${CORE}/arch-mapping.sh"

for _arch in amd64 arm64 riscv64; do
  t_case "uname-name parity for ${_arch}"
  t_assert_eq "$(arch_uname_name_for "${_arch}")" \
              "$(_fallback "smoke_uname_name ${_arch}")" \
              "smoke-common fallback diverged from platform.sh"

  t_case "ELF-machine parity for ${_arch}"
  # smoke_elf_machine_grep is a GREP PATTERN; canonical arch_to_elf_machine is
  # the full readelf string — parity means the pattern MATCHES the canonical.
  t_assert_contains "$(arch_to_elf_machine "${_arch}")" \
              "$(_fallback "smoke_elf_machine_grep ${_arch}")" \
              "smoke-common grep pattern no longer matches the canonical ELF machine string"
done

t_case "host-arch normalization parity"
for _m in x86_64 aarch64 riscv64; do
  t_assert_eq "$(arch_normalize "${_m}")" "$(_fallback "smoke_host_arch ${_m}")"
done

t_case "smoke_arch_words splits under strict IFS (the historical bug class)"
_count="$(_fallback "IFS=\$'\n\t'; set -- \$(smoke_arch_words 'amd64,arm64,riscv64'); echo \$#")"
t_assert_eq "3" "${_count}" "comma list must yield 3 words under IFS=\$'\\n\\t'"

t_case "arch_list_to_words splits under strict IFS too"
_count="$(bash -c "source '${CORE}/platform.sh'; source '${CORE}/build-helpers.sh'; IFS=\$'\n\t'; set -- \$(arch_list_to_words 'amd64,arm64,riscv64'); echo \$#" 2>/dev/null)"
t_assert_eq "3" "${_count}" "the 16 latent for-loop sites are safe only if this splits"


# ── ARCH-PARITY component table (2026-08-23) ────────────────────────────────
# smoke-runtime-image.sh asserts that every component NAMED in its parity table
# is present on the arch it is smoking, modulo a per-arch exception list that IS
# the reviewed record of the deltas (riscv64 has no CMake archive upstream, and
# the IREE compiler cannot be cross-built). GEN1 dropped the genai exemption:
# docs/gen1-riscv64-genai.md. Scope, stated precisely because the earlier
# wording here oversold it: the smoke sees ONE image per run, so it conforms an
# arch to the table — it does not diff arch against arch, and a component in
# NEITHER the table nor the exception list is outside the gate on every arch.
# The table only works if it stays honest, so lint it here: an exemption for a
# component nobody tracks is dead text, and a tracked component nobody can ever
# satisfy would fail every arch forever.

RT_SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

# Load the table + its helpers WITHOUT running main(): copy the script minus
# its last line (`main "$@"`) next to the smoke-common.sh it sources, then run
# expressions against it in a clean shell.
_RT_SANDBOX="$(mktemp -d)"
trap 'rm -rf "${_RT_SANDBOX}"' EXIT
sed '$d' "${RT_SMOKE}" > "${_RT_SANDBOX}/rt.sh"
cp "${TESTS_DIR}/../06-packaging/smoke-common.sh" "${_RT_SANDBOX}/"
_rt_table() {
  bash -c "source '${_RT_SANDBOX}/rt.sh' >/dev/null 2>&1; $1"
}

t_case "the sandbox trick still holds: main() is invoked on the LAST line"
# `sed '$d'` above only strips the entry point if it is the final line; if the
# file grows a trailer, every assertion below would silently execute main().
t_assert_eq 'main "$@"' "$(tail -1 "${RT_SMOKE}")"

t_case "parity table lists both prefixes and wheels"
t_assert_contains "$(_rt_table 'printf "%s" "${_PARITY_PREFIXES}"')" "cmake"
t_assert_contains "$(_rt_table 'printf "%s" "${_PARITY_WHEELS}"')" "onnxruntime_genai"

t_case "every documented exemption names a component the table actually tracks"
# Parse the case arms of _parity_exempt: "<arch>:<component>)". Scoped to that
# function: the file holds other <arch>:<name>) tables (the consumer contract) whose
# components this one does not track.
_tracked="$(_rt_table 'printf "%s %s" "${_PARITY_PREFIXES}" "${_PARITY_WHEELS}"')"
_orphans=""
while IFS= read -r _arm; do
  _comp="${_arm#*:}"
  case " ${_tracked} " in
    *" ${_comp} "*) ;;
    *) _orphans="${_orphans} ${_arm}" ;;
  esac
done < <(t_fn_src "${RT_SMOKE}" _parity_exempt \
         | sed -n 's/^[[:space:]]*\(amd64\|arm64\|riscv64\):\([A-Za-z0-9_.+-]*\)).*/\1:\2/p' \
         | grep -v ':libgst')
t_assert_eq "" "${_orphans}" "exemption(s) for components the parity table does not track (dead entries)"

t_case "_parity_exempt only exempts what it documents"
t_assert_ok   _rt_table '_parity_exempt riscv64 cmake'
t_assert_ok   _rt_table '_parity_exempt riscv64 iree_base_compiler'
# GEN1: the exemption is gone and must STAY gone. docs/gen1-riscv64-genai.md
t_assert_fails _rt_table '_parity_exempt riscv64 onnxruntime_genai'
t_assert_fails _rt_table '_parity_exempt amd64 cmake'
t_assert_fails _rt_table '_parity_exempt riscv64 ffmpeg'

t_case "every shipped arch has a declared onnxruntime flavour"
for _arch in amd64 arm64 riscv64; do
  t_assert_contains "$(_rt_table "_parity_ort_flavor ${_arch}")" "onnxruntime_"
done

t_case "the gtk4 arm64 load failure is documented, and only for arm64"
t_assert_ok    _rt_table '_parity_gst_plugin_known arm64 libgstgtk4.so'
t_assert_fails _rt_table '_parity_gst_plugin_known amd64 libgstgtk4.so'
t_assert_fails _rt_table '_parity_gst_plugin_known arm64 libgstcoreelements.so'

# ── generated ONNX fixture (SMOKE-DEPTH c) ──────────────────────────────────
# The fixture replaced a check that had been printing SKIP on every arch since
# it was written, so prove THIS one cannot go quiet: drive it against stub
# numpy/onnxruntime modules and assert all three exit paths, plus that a real
# ONNX graph (op "Add", the three tensor names) reaches the session.

# NB: smoke-common.sh sets -euo pipefail, so it is loaded in a SUBSHELL — a
# top-level `source` would arm errexit here and abort the suite on the first
# deliberately-failing assertion below.
_ONNX_PY="${_RT_SANDBOX}/onnx_fixture.py"
bash -c "source '${TESTS_DIR}/../06-packaging/smoke-common.sh'; smoke_minimal_onnx_py" \
  > "${_ONNX_PY}"

_STUB="${_RT_SANDBOX}/stubs"
mkdir -p "${_STUB}"
cat > "${_STUB}/numpy.py" <<'PY'
float32 = "float32"
class _Arr:
    def __init__(self, v): self.v = v
    def tolist(self): return self.v
def array(v, dtype=None): return _Arr(v)
PY
cat > "${_STUB}/onnxruntime.py" <<'PY'
import os
__version__ = "stub"
def get_available_providers(): return ["StubEP"]
class InferenceSession:
    def __init__(self, model, providers=None):
        with open(os.environ["ONNX_STUB_MODEL"], "wb") as f:
            f.write(model)
    def get_providers(self): return ["StubEP"]
    def run(self, outputs, feeds):
        import numpy
        if os.environ.get("ONNX_STUB_ANSWER") == "wrong":
            return [numpy.array([[0.0, 0.0, 0.0, 0.0]])]
        return [numpy.array([[11.0, 22.0, 33.0, 44.0]])]
PY

t_case "smoke_minimal_onnx_py emits a program that RUNS a session (not a skip)"
t_assert_ok python3 -m py_compile "${_ONNX_PY}"
_model="${_STUB}/model.onnx"
_out="$(ONNX_STUB_MODEL="${_model}" PYTHONPATH="${_STUB}" python3 "${_ONNX_PY}" 2>&1)"; _rc=$?
t_assert_eq "0" "${_rc}" "the fixture must reach InferenceSession.run: ${_out}"
t_assert_contains "${_out}" "ONNX-EP OK"
t_assert_contains "${_out}" "StubEP"

t_case "the emitted model is a real ONNX graph, not a placeholder"
t_assert_ok test -s "${_model}"
t_assert_ok grep -aq "Add" "${_model}"        # the op type reached the session
for _tensor in X Y Z; do
  t_assert_ok grep -aq "${_tensor}" "${_model}"
done

t_case "a wrong inference result FAILS (the assert has teeth)"
_out="$(ONNX_STUB_MODEL="${_model}" ONNX_STUB_ANSWER=wrong PYTHONPATH="${_STUB}" \
        python3 "${_ONNX_PY}" 2>&1)"; _rc=$?
t_assert_eq "1" "${_rc}" "a bad result must exit 1, not pass"
t_assert_contains "${_out}" "ONNX-EP FAIL"

t_case "no onnxruntime -> exit 3 (skip), never a crash or a false pass"
_out="$(PYTHONPATH="/nonexistent" python3 "${_ONNX_PY}" 2>&1)"; _rc=$?
t_assert_eq "3" "${_rc}" "the skip path must be a clean 3: ${_out}"
t_assert_contains "${_out}" "ONNX-EP SKIP"

# ── ONNX-EP sentinel: exit status is not evidence (2026-08-23 remediation) ──
# check_onnx_execution_provider ships the program to the container in an ENV
# VAR and feeds it to `python -`. When that var does not arrive, python reads an
# EMPTY program and exits 0 — the check used to print PASS. Both defences are
# pinned here: the in-image `-z` guard, and (with that guard deleted) the
# host-side requirement that the program's own ONNX-EP sentinel appear in the
# OUTPUT. The harness replaces _rt_run with a local runner, so no container and
# no image are needed; the -e forwarding it emulates IS the boundary under test.
_EP="${_RT_SANDBOX}/ep"
mkdir -p "${_EP}/venv/bin"
cat > "${_EP}/venv/bin/python" <<EOF
#!/bin/sh
exec env PYTHONPATH="${_STUB}" python3 "\$@"
EOF
chmod +x "${_EP}/venv/bin/python"
# The stub session refuses a truncated model, so "the program ran" cannot be
# faked by a few stray bytes.
cat > "${_STUB}/onnxruntime.py" <<'PY'
import os
__version__ = "stub"
def get_available_providers(): return ["StubEP"]
class InferenceSession:
    def __init__(self, model, providers=None):
        assert model and len(model) > 50, "empty/short model reached the session"
        p = os.environ.get("ONNX_STUB_MODEL")
        if p:
            with open(p, "wb") as f:
                f.write(model)
    def get_providers(self): return ["StubEP"]
    def run(self, outputs, feeds):
        import numpy
        if os.environ.get("ONNX_STUB_ANSWER") == "wrong":
            return [numpy.array([[0.0, 0.0, 0.0, 0.0]])]
        return [numpy.array([[11.0, 22.0, 33.0, 44.0]])]
PY

# $1 = mutation: none | blank-emitter | drop-env | no-guard-drop-env
_ep_drive() {
  bash -c '
S="$1"; EP="$2"; STUB="$3"; MUT="$4"
source "${S}/rt.sh" >/dev/null 2>&1
_rt_run() {
  local -a envs=()
  while [ "${1:-}" = "-e" ]; do
    case "${MUT}" in *drop-env*) ;; *) envs+=("$2") ;; esac
    shift 2
  done
  local prog="$*"; prog="${prog#bash -lc }"
  prog="${prog//\/opt\/venv\/bin\/python/${EP}/venv/bin/python}"
  case "${MUT}" in
    no-guard*) prog="$(printf "%s" "${prog}" | sed "/^if \[ -z /,/^fi$/d")" ;;
  esac
  env "${envs[@]+"${envs[@]}"}" bash -lc "${prog}"
}
if [ "${MUT}" = "blank-emitter" ]; then smoke_minimal_onnx_py() { :; }; fi
FAILURES=0
check_onnx_execution_provider "sandbox-image" "amd64" 2>&1
echo "FAILURES=${FAILURES}"
' _ "${_RT_SANDBOX}" "${_EP}" "${_STUB}" "$1"
}

t_case "ONNX-EP check passes only on a real run (baseline: the program arrives)"
_ep_out="$(_ep_drive none)"
t_assert_contains "${_ep_out}" "FAILURES=0"
t_assert_contains "${_ep_out}" "ONNX-EP OK:"
t_assert_contains "${_ep_out}" "StubEP"

t_case "a silent emitter turns the check RED (mutation: smoke_minimal_onnx_py prints nothing)"
_ep_out="$(_ep_drive blank-emitter)"
t_assert_contains "${_ep_out}" "FAILURES=1"

t_case "an env var that never crosses the boundary turns the check RED"
_ep_out="$(_ep_drive drop-env)"
t_assert_contains "${_ep_out}" "FAILURES=1"

t_case "with the in-image guard ALSO removed, the OUTPUT sentinel is what fails it"
# This is the reviewed defect reproduced exactly: `printf "" | python -` exits
# 0, so nothing but the missing ONNX-EP token can catch it. If this case ever
# reports FAILURES=0, the check has gone back to trusting exit status.
_ep_out="$(_ep_drive no-guard-drop-env)"
t_assert_contains "${_ep_out}" "FAILURES=1"
t_assert_contains "${_ep_out}" "NO ONNX-EP sentinel"

t_case "and the emitter is intact — the mutations live only in the harness"
t_assert_contains "$(bash -c "source '${TESTS_DIR}/../06-packaging/smoke-common.sh'; smoke_minimal_onnx_py")" \
  "ONNX-EP OK:"

# ── check_default_entrypoint_boot must never self-disable ───────────────────
# inspect_image_config swallows every error into "" (`|| true`), and the check
# used to treat "" and a non-shell CMD identically: INFO + return 0, no failure
# recorded. A gate that stands itself down on an inspect error is not a gate.
_boot_drive() {
  bash -c '
S="$1"; CMDJSON="$2"
source "${S}/rt.sh" >/dev/null 2>&1
inspect_image_config() { printf "%s" "${CMDJSON}"; }
NERDCTL_BIN="${S}/fake-nerdctl"
FAILURES=0
check_default_entrypoint_boot "sandbox-image" "amd64" 2>&1
echo "FAILURES=${FAILURES}"
' _ "${_RT_SANDBOX}" "$1"
}
cat > "${_RT_SANDBOX}/fake-nerdctl" <<'SH'
#!/usr/bin/env bash
# Only the boot probe's `run --rm -i <image>` shape is used: execute the piped
# script with the env the entrypoint is supposed to have exported.
# The shapes matter, not just set-ness: the multiarch plugin dir and a RESOLVED
# VULKAN_SDK are what only gstreamer-env.sh adds, and the gate now checks for
# them. /fake/gst would answer "set" with the sourcing gone. Backlog XQ.
exec env GST_PLUGIN_PATH=/opt/gstreamer/lib/x86_64-linux-gnu/gstreamer-1.0 \
         VULKAN_SDK=/opt/vulkan/1.4.357.0/x86_64 bash -s
SH
chmod +x "${_RT_SANDBOX}/fake-nerdctl"

t_case "an inspect failure FAILS the boot check instead of skipping it"
_boot_out="$(_boot_drive "")"
t_assert_contains "${_boot_out}" "FAILURES=1"
t_assert_contains "${_boot_out}" "could not read Config.Cmd"

t_case 'CMD ["bash","-l"] still runs the probe (only the FIRST word is matched)'
_boot_out="$(_boot_drive "CMDOK bash -l")"
t_assert_contains "${_boot_out}" "FAILURES=0"
t_assert_contains "${_boot_out}" "exit status propagated"

t_case "the shipped CMD [/bin/bash] runs the probe"
_boot_out="$(_boot_drive "CMDOK /bin/bash")"
t_assert_contains "${_boot_out}" "FAILURES=0"

t_case "a non-shell CMD FAILS loudly rather than disabling the probe"
_boot_out="$(_boot_drive "CMDOK /opt/venv/bin/python app.py")"
t_assert_contains "${_boot_out}" "FAILURES=1"

# ── GStreamer failure count must not shrink under classification ────────────
# The classifier counts UNIQUE libgst*.so basenames; the metric watched since
# wave-4 is the raw "Failed to load plugin" LINE count. Reporting the former as
# the latter silently lowers a regression number. Both must appear.
_gst_drive() {
  bash -c '
S="$1"; SCAN="$2"
source "${S}/rt.sh" >/dev/null 2>&1
_rt_run() { printf "%s\n" "${SCAN}"; }
FAILURES=0
check_gstreamer_plugin_health "sandbox-image" "arm64" 2>&1
echo "FAILURES=${FAILURES}"
' _ "${_RT_SANDBOX}" "$1"
}
# 3 failure lines: the SAME basename from two plugin dirs (the collapse case),
# plus one message that names no libgst*.so at all (the dropped case).
_GST_SCAN='(gst-plugin-scanner:9): GStreamer-WARNING **: Failed to load plugin '"'"'/opt/gstreamer/lib/gstreamer-1.0/libgstgtk4.so'"'"': libgtk-4.so.1: undefined symbol: vkCreateWaylandSurfaceKHR
(gst-plugin-scanner:9): GStreamer-WARNING **: Failed to load plugin '"'"'/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstgtk4.so'"'"': libgtk-4.so.1: undefined symbol: vkCreateWaylandSurfaceKHR
(gst-plugin-scanner:9): GStreamer-WARNING **: Failed to load plugin '"'"'/opt/gstreamer/lib/gstreamer-1.0/oddly-named-plugin'"'"': cannot open shared object file
GST_SCAN_DONE'

t_case "the headline count stays the RAW failure-line count, not the unique-basename count"
_gst_out="$(_gst_drive "${_GST_SCAN}")"
t_assert_contains "${_gst_out}" "cannot load: 3 (non-fatal)"

t_case "the classification detail is reported on its own, clearly labelled, denominator"
t_assert_contains "${_gst_out}" "1 documented, 0 undocumented"
t_assert_contains "${_gst_out}" "1 failure line(s) name no libgst*.so"

t_case "plugin health is WARN-only: a documented failure never fails the smoke"
t_assert_contains "${_gst_out}" "FAILURES=0"

t_case "a scan that never completed reports UNKNOWN, not a healthy 0"
# An empty scan is what a HEALTHY image prints too, so without the probe's own
# completion stamp "0 plugins cannot load" would be a false green.
_gst_out="$(_gst_drive "")"
t_assert_contains "${_gst_out}" "UNKNOWN, not 0"
t_assert_ok test -z "$(printf '%s\n' "${_gst_out}" | grep -F 'cannot load: 0' || true)"

# ── GENAI-DRIFT: the tolerance must be EXACTLY one reviewed case ────────────
# assert_pinned_versions now lets a versions.env build pin overrule the app
# lock. That is correct, and on arm64 it is also RED today (genai 0.14.0 vs a
# v0.15.2 pin) with the producer-side fix still open — while the assert is a
# hard gate ahead of the manifest push. So the known case is a dated one-line
# KNOWN_DRIFT entry. This suite is what stops that line from widening into a
# blanket exemption: same drift on another arch, or a different version on
# either side, must still FAIL.
_STV="${_RT_SANDBOX}/stv"
mkdir -p "${_STV}/stubs/PIL" "${_STV}/stubs/ai_edge_litert" "${_STV}/venv/bin"
sed '$d' "${TESTS_DIR}/../06-packaging/smoke-torch-venv.sh" > "${_STV}/stv.sh"
cp "${TESTS_DIR}/../06-packaging/smoke-common.sh" "${_STV}/"
for _m in torch torchvision onnxruntime numpy contourpy onnxruntime_genai; do
  printf 'import os\n__version__ = os.environ["STUB_%s"]\n' "$(printf '%s' "${_m}" | tr '[:lower:]' '[:upper:]')" \
    > "${_STV}/stubs/${_m}.py"
done
printf 'import os\n__version__ = os.environ["STUB_PIL"]\n' > "${_STV}/stubs/PIL/__init__.py"
printf 'import os\n__version__ = os.environ["STUB_AI_EDGE_LITERT"]\n' > "${_STV}/stubs/ai_edge_litert/__init__.py"
cat > "${_STV}/venv/bin/python" <<EOF
#!/bin/sh
exec env PYTHONPATH="${_STV}/stubs" python3 "\$@"
EOF
chmod +x "${_STV}/venv/bin/python"
cat > "${_STV}/versions.env" <<'ENVEOF'
PYTORCH_VERSION=v2.13.0
TORCHVISION_VERSION=v0.28.0
ONNXRUNTIME_VERSION=v1.29.0
LITERT_VERSION=v1.5.0
ONNXRUNTIME_GENAI_VERSION=v0.15.2
OPENCV_VERSION=5.0.0
ENVEOF

# $1 = arch, $2 = installed genai version, $3 = optional uv.lock path,
# $4 = one optional extra VAR=VALUE (`env -i` below eats anything else).
# Default: no uv.lock, which isolates the build-pin path. Pass a lock to
# exercise the AUTHORITY rule itself (see the lock-vs-pin case below).
_stv_drive() {
  local _extra="${4:-STV_DRIVE_UNUSED=1}"
  env -i PATH="${PATH}" HOME="${HOME}" "${_extra}" \
    VENV="${_STV}/venv" VERSIONS_ENV="${_STV}/versions.env" \
    APP_UV_LOCK="${3:-${_STV}/no-such.lock}" STV_ARCH="$1" STV_CV2_REQUIRED=0 \
    STUB_TORCH=2.13.0+cpu STUB_TORCHVISION=0.28.0+cpu STUB_ONNXRUNTIME=1.29.0 \
    STUB_NUMPY=2.5.1 STUB_PIL=11.0.0 STUB_CONTOURPY=1.3.0 \
    STUB_AI_EDGE_LITERT=1.5.0 STUB_ONNXRUNTIME_GENAI="$2" \
    bash -c "source '${_STV}/stv.sh' >/dev/null 2>&1; FAILURES=0; assert_pinned_versions 2>&1; echo \"FAILURES=\${FAILURES}\""
}

t_case "the arm64 genai drift is a FAILURE again -- the tolerance was earned away"
# Until 2026-08-27 this asserted the opposite: arm64 at 0.14.0 was TOLERATED
# because the producer could not build the wheel. It can now, and today's run
# shipped 0.15.2 on amd64 AND arm64 with no drift message at all, so the
# KNOWN_DRIFT arm was deleted and the assert is armed again. Pinning the
# re-arming matters more than pinning the tolerance did: a silent regression to
# 0.14.0 is exactly what the tolerance used to hide.
_stv_out="$(_stv_drive arm64 0.14.0)"
t_assert_contains "${_stv_out}" "FAILURES=1"
t_assert_ok test -z "$(printf '%s\n' "${_stv_out}" | grep -F 'TOLERATED' || true)"

# REGRESSION GUARD (adversarial review 2026-08-23): every case above runs with
# a NON-EXISTENT uv.lock, so `from_lock` is always empty — which makes the new
# "a versions.env BUILD pin is authoritative" rule indistinguishable from the
# old "lock UNION pin" rule. Reverting the fix left the suite green. This case
# supplies a real lock whose genai version DIFFERS from the pin: under the
# union rule the lock value would be accepted (FAILURES=0), under the authority
# rule only the pin counts, so the installed lock-version must FAIL.
t_case "a uv.lock version does NOT satisfy a versions.env BUILD pin (authority, not union)"
cat >"${_STV}/uv.lock" <<'LOCKEOF'
version = 1
requires-python = ">=3.14"

[[package]]
name = "onnxruntime-genai"
version = "0.13.0"
source = { registry = "https://pypi.org/simple" }
LOCKEOF
# amd64 so the dated arm64 tolerance cannot mask the result; installed == the
# LOCK's version, which the pin (0.15.2) does not allow.
_stv_out="$(_stv_drive amd64 0.13.0 "${_STV}/uv.lock")"
t_assert_contains "${_stv_out}" "NOT in expected"
# FAILURES must be NON-zero — under the old union rule the lock value would
# have satisfied the pin and this would read FAILURES=0.
t_assert_eq "1" "$(printf '%s' "${_stv_out}" | grep -c 'FAILURES=[1-9]')"

t_case "the SAME drift on another arch still FAILS (not a blanket genai exemption)"
_stv_out="$(_stv_drive amd64 0.14.0)"
t_assert_contains "${_stv_out}" "FAILURES=1"
t_assert_contains "${_stv_out}" "NOT in expected"

t_case "a DIFFERENT installed version on arm64 still FAILS (new deviation, unknown)"
_stv_out="$(_stv_drive arm64 0.13.0)"
t_assert_contains "${_stv_out}" "FAILURES=1"

t_case "once the producer ships the pinned version, the arm64 case is a plain OK"
_stv_out="$(_stv_drive arm64 0.15.2)"
t_assert_contains "${_stv_out}" "FAILURES=0"
t_assert_ok test -z "$(printf '%s\n' "${_stv_out}" | grep -F 'TOLERATED' || true)"

# ── GEN1: the riscv64 genai policy, whose arm had NO case at all ─────────────
# Pinned in both directions; docs/gen1-riscv64-genai.md
t_case "GEN1: a riscv64 image WITHOUT genai is now a FAILURE, not a documented skip"
_stv_out="$(_stv_drive riscv64 "")"
t_assert_contains "${_stv_out}" "onnxruntime-genai NOT INSTALLED"
t_assert_eq "1" "$(printf '%s' "${_stv_out}" | grep -c 'FAILURES=[1-9]')"

t_case "GEN1: a riscv64 image WITH the pinned genai passes clean"
_stv_out="$(_stv_drive riscv64 0.15.2)"
t_assert_contains "${_stv_out}" "FAILURES=0"

t_case "GEN1: the escape hatch, and ONLY the escape hatch, restores the tolerance"
# With the lane off the producer emits nothing, so absence is policy again.
_stv_out="$(_stv_drive riscv64 "" "" GENAI_ALLOW_RISCV64=false)"
t_assert_contains "${_stv_out}" "FAILURES=0"
t_assert_contains "${_stv_out}" "GENAI_ALLOW_RISCV64"
# ...and the hatch is riscv64-scoped: it must not silence amd64.
_stv_out="$(_stv_drive amd64 "" "" GENAI_ALLOW_RISCV64=false)"
t_assert_eq "1" "$(printf '%s' "${_stv_out}" | grep -c 'FAILURES=[1-9]')"

t_case "KNOWN_DRIFT: every entry is reviewed, dated and backlog-linked"
# The previous version asserted the COUNT was exactly 1, while its own comment
# said "deleting that single line must be all it takes to re-arm the assert".
# Those contradict: on 2026-08-27 arm64 shipped onnxruntime-genai 0.15.2 by
# itself, the arm was correctly deleted -- and this test went red for doing the
# thing it asked for. Assert the SHAPE of whatever is present instead. Empty is
# the desired steady state and passes vacuously; a sloppy new arm still fails.
_kd_block="$(sed -n '/^KNOWN_DRIFT = \[/,/^\]/p' "${TESTS_DIR}/../06-packaging/smoke-torch-venv.sh")"
_kd="$(printf '%s\n' "${_kd_block}" | grep -c '^    ("' || true)"
t_assert_ok test "${_kd}" -le 2
_kd_bad="$(printf '%s\n' "${_kd_block}" | grep '^    ("' \
            | grep -cv '20[0-9][0-9]-[01][0-9]-[0-3][0-9]' || true)"
t_assert_eq "0" "${_kd_bad}" "a KNOWN_DRIFT arm without a review date"

# ── D3: the shared binary/component gate helpers ────────────────────────────
# smoke-media.sh hand-wrote four idioms at 5 + 4 + 2 sites (plus an 11th private
# copy of the arch -> ELF-machine map in smoke-android.sh). They live in
# smoke-common.sh now. Two separate things are pinned below, because either one
# alone rots: (A) the helpers BEHAVE, including their FAILURE directions — an
# idiom that can only ever pass is precisely what this repo keeps shipping by
# accident; and (B) the call sites STAY deduplicated — a dedup that no test
# protects drifts back apart at the next edit.

_SMOKE_DIR="${TESTS_DIR}/../06-packaging"

# Run an expression against smoke-common.sh in a CLEAN bash (so the fallback
# cross_build_is_active is the one under test), merging stderr — fail() writes
# there. _scf also reports the FAILURES counter, which is how "did this idiom
# actually record a failure" is observed from outside.
_sc()  { bash -c "source '${SMOKE_COMMON}' >/dev/null 2>&1; $1" 2>&1; }
_scf() { bash -c "source '${SMOKE_COMMON}' >/dev/null 2>&1; $1; echo \"FAILURES=\${FAILURES}\"" 2>&1; }

# ── A. behaviour ────────────────────────────────────────────────────────────

t_case "smoke_resolve_bin prefers PATH and otherwise returns the fallback verbatim"
t_assert_eq "$(command -v sh)" "$(_sc 'smoke_resolve_bin sh /nowhere/sh')"
t_assert_eq "/opt/ffmpeg/bin/ffmpeg" \
            "$(_sc 'smoke_resolve_bin containerhub-no-such-tool /opt/ffmpeg/bin/ffmpeg')"

t_case "smoke_resolve_bin never trips errexit on the miss path"
# The four call sites are `x="$(smoke_resolve_bin …)"` under `set -euo
# pipefail`; a non-zero rc there would kill the smoke instead of falling back.
t_assert_eq "reached" \
  "$(_sc 'x="$(smoke_resolve_bin containerhub-no-such-tool /opt/x)"; [ "$x" = /opt/x ] && echo reached')"

# ELF fixtures: a real magic header, a text file, an empty file.
printf '\177ELF\002\001\001\000' > "${_RT_SANDBOX}/fake.elf"
printf 'this is not an ELF binary' > "${_RT_SANDBOX}/fake.txt"
: > "${_RT_SANDBOX}/empty.bin"

t_case "smoke_is_elf accepts the magic and rejects text/empty/missing"
t_assert_ok    bash -c "source '${SMOKE_COMMON}'; smoke_is_elf '${_RT_SANDBOX}/fake.elf'"
t_assert_fails bash -c "source '${SMOKE_COMMON}'; smoke_is_elf '${_RT_SANDBOX}/fake.txt'"
t_assert_fails bash -c "source '${SMOKE_COMMON}'; smoke_is_elf '${_RT_SANDBOX}/empty.bin'"
t_assert_fails bash -c "source '${SMOKE_COMMON}'; smoke_is_elf '${_RT_SANDBOX}/no-such-file'"

t_case "a missing file is a clean 'not ELF', not an errexit abort"
# `head` failing inside the pipeline under `set -o pipefail` must be absorbed;
# otherwise the ffmpeg/gst deferral paths would kill the whole smoke.
t_assert_eq "reached" \
  "$(_sc "smoke_is_elf '${_RT_SANDBOX}/no-such-file' || true; echo reached")"

t_case "smoke_deferred_if_elf: a real ELF is INFO — deferred, never a PASS"
_d_out="$(_scf "smoke_deferred_if_elf ffmpeg '${_RT_SANDBOX}/fake.elf' 'not executable in build sandbox'")"
t_assert_contains "${_d_out}" "INFO: not executable in build sandbox"
t_assert_contains "${_d_out}" "FAILURES=0"
t_assert_eq "" "$(printf '%s' "${_d_out}" | grep -F 'PASS' || true)" \
  "a deferral must not be reported as a pass"

t_case "smoke_deferred_if_elf: a corrupt/non-ELF file FAILS (the gate has teeth)"
_d_out="$(_scf "smoke_deferred_if_elf ffmpeg '${_RT_SANDBOX}/fake.txt' 'not executable in build sandbox'")"
t_assert_contains "${_d_out}" "ffmpeg at ${_RT_SANDBOX}/fake.txt is not an ELF binary"
t_assert_contains "${_d_out}" "FAILURES=1"

t_case "smoke_cross_presence_gate fires only under a real cross build"
_g_out="$(_scf 'BUILD_MODE=cross TARGET_ARCH=riscv64 BUILDARCH=x86_64 smoke_cross_presence_gate ffmpeg /opt/ffmpeg/bin/ffmpeg')"
t_assert_contains "${_g_out}" "PASS ffmpeg binary present at /opt/ffmpeg/bin/ffmpeg (cross build — execution skipped)"
t_assert_contains "${_g_out}" "FAILURES=0"

t_case "the noun/action pair carries the library and Python-bindings wordings"
t_assert_contains \
  "$(_sc 'BUILD_MODE=cross TARGET_ARCH=arm64 BUILDARCH=x86_64 smoke_cross_presence_gate opencv /opt/opencv5/lib "Python bindings" import')" \
  "opencv Python bindings present at /opt/opencv5/lib (cross build — import skipped)"
t_assert_contains \
  "$(_sc 'BUILD_MODE=cross TARGET_ARCH=arm64 BUILDARCH=x86_64 smoke_cross_presence_gate onnxruntime /usr/local/lib/onnxruntime-cpu library import')" \
  "onnxruntime library present at /usr/local/lib/onnxruntime-cpu (cross build — import skipped)"

t_case "on a NATIVE build the gate declines (rc 1) and prints NOTHING"
# The smoke-media sites use it as an `if` head: a gate that returned 0, or that
# printed a PASS here, would skip the functional checks on a native build —
# which is exactly the silent-skip class smoke-common's own header records.
t_assert_eq "DECLINED" \
  "$(_sc 'BUILD_MODE=native smoke_cross_presence_gate ffmpeg /opt/ffmpeg/bin/ffmpeg || echo DECLINED')"

t_case "a cross build whose target EQUALS the build arch is not cross either"
t_assert_eq "DECLINED" \
  "$(_sc 'BUILD_MODE=cross TARGET_ARCH=amd64 BUILDARCH=x86_64 smoke_cross_presence_gate ffmpeg /opt/ffmpeg/bin/ffmpeg || echo DECLINED')"

t_case "smoke_elf_machine_of agrees with the canonical arch map on a real binary"
if command -v readelf >/dev/null 2>&1; then
  _self_bin="$(command -v bash)"
  t_assert_contains "$(_sc "smoke_elf_machine_of '${_self_bin}'")" \
    "$(arch_elf_machine_grep_for "$(arch_normalize "$(uname -m)")")" \
    "the extracted readelf pipeline no longer matches platform.sh's map"
  t_assert_eq "" "$(_sc "smoke_elf_machine_of '${_RT_SANDBOX}/fake.txt' || true")" \
    "a non-ELF file must yield an empty machine string, not garbage"
else
  # No readelf on this host: still assert something, so the coverage count
  # cannot silently collapse (run-tests.sh aggregates it for exactly this).
  t_assert_eq "" "$(_sc "smoke_elf_machine_of '${_RT_SANDBOX}/fake.elf' || true")"
fi

# ── B. drift guard: the idioms must live ONLY in smoke-common.sh ────────────
# Scope = the in-image smoke scripts under 06-packaging. smoke-runtime-image.sh
# is excluded by review, not convenience: it is a HOST-side driver whose
# `command -v … || echo …` sites sit inside `bash -lc '…'` payloads that execute
# in ANOTHER container, where smoke-common.sh is not sourced and the helper
# cannot exist. Every other smoke-*.sh is in scope automatically, so a NEW one
# is covered the day it lands.
_EXCLUDED_FROM_DEDUP="smoke-common.sh smoke-runtime-image.sh"

_dedup_targets() {
  local f
  for f in "${_SMOKE_DIR}"/smoke-*.sh; do
    case " ${_EXCLUDED_FROM_DEDUP} " in
      *" $(basename "${f}") "*) continue ;;
    esac
    printf '%s\n' "${f}"
  done
}

# Full-line comments are blanked before matching (same rationale as
# test-invocation-lints.sh): these lints ban an idiom from EXECUTING, and prose
# that merely describes it — including the comments explaining why the helper
# exists — cannot run.
_dedup_scan() {   # <extended-regex> -> "file:line: text" per hit
  local re="$1" f
  for f in $(_dedup_targets); do
    sed 's/^[[:space:]]*#.*$//' "${f}" | grep -nE "${re}" \
      | sed "s|^|$(basename "${f}"):|" || true
  done
}

t_case "the drift scan actually reaches the smoke scripts (positive control)"
# This repo has already shipped a lint that scanned ZERO files and reported
# three green assertions for two weeks (see test-invocation-lints.sh's header).
# "Found nothing" is what success looks like here, so prove the scan runs:
# the file list is non-empty, includes smoke-media.sh, and a pattern that IS
# still present in it is found.
t_assert_ok test "$(_dedup_targets | wc -l)" -ge 4
t_assert_contains "$(_dedup_targets)" "smoke-media.sh"
t_assert_contains "$(_dedup_scan 'smoke_cross_presence_gate')" "smoke-media.sh:"

t_case "no re-inlined smoke_resolve_bin (command -v … || echo <fallback>)"
t_assert_eq "" "$(_dedup_scan 'command -v [^|]*\|\|[[:space:]]*echo')" \
  "use smoke_resolve_bin from smoke-common.sh"

t_case "no re-inlined ELF-magic test (head -c4 … | tail -c3)"
t_assert_eq "" "$(_dedup_scan 'head -c ?4.*tail -c ?3')" \
  "use smoke_is_elf / smoke_deferred_if_elf from smoke-common.sh"

t_case "no re-inlined cross-presence PASS message"
# Bans the template the helper owns: "<label> <noun> present at <path> (cross
# build — <action> skipped)". The two deliberately different messages in
# smoke-media.sh — the pathless genai one, and the opencv foreign-arch-extension
# one — do not match this shape and stay out of the helper on purpose.
t_assert_eq "" "$(_dedup_scan 'present at .*\(cross build — .* skipped\)')" \
  "use smoke_cross_presence_gate from smoke-common.sh"

t_case "no re-inlined readelf Machine: pipeline"
t_assert_eq "" "$(_dedup_scan 'readelf -h')" \
  "use smoke_elf_machine_of from smoke-common.sh"
# …and smoke-common.sh itself must hold exactly ONE copy — the helper. It is
# excluded from the scan above (it is where the idiom belongs), so without this
# the two sites it feeds, _cc_check_binary_elf and _cc_check_object, could
# quietly grow their own pipelines back.
t_assert_eq "1" "$(sed 's/^[[:space:]]*#.*$//' "${SMOKE_COMMON}" | grep -c 'readelf -h')" \
  "smoke-common.sh must define the readelf pipeline once, in smoke_elf_machine_of"

t_case "no private copy of the arch -> ELF-machine map"
t_assert_eq "" "$(_dedup_scan '\*(AArch64|X86-64|RISC-V)\*')" \
  "use smoke_elf_machine_grep from smoke-common.sh"

t_case "each banned pattern would still catch a re-inlined site (negative control)"
# A regex that has quietly stopped matching is indistinguishable from a clean
# tree. Feed each one the exact line it was written to ban.
_dedup_probe() { printf '%s\n' "$2" | grep -qE "$1" && echo HIT || echo MISS; }
t_assert_eq "HIT" "$(_dedup_probe 'command -v [^|]*\|\|[[:space:]]*echo' \
  '_cam_bin="$(command -v cam 2>/dev/null || echo "${_lc_prefix}/bin/cam")"')"
t_assert_eq "HIT" "$(_dedup_probe 'head -c ?4.*tail -c ?3' \
  'if [ "$(head -c4 "${_ffmpeg_bin}" 2>/dev/null | tail -c3 || true)" = "ELF" ]; then')"
t_assert_eq "HIT" "$(_dedup_probe 'present at .*\(cross build — .* skipped\)' \
  'pass "cam binary present at ${_cam_bin} (cross build — execution skipped)"')"
t_assert_eq "HIT" "$(_dedup_probe 'readelf -h' \
  'm="$(LC_ALL=C readelf -h "${o}" | sed -n "s/Machine://p" | head -1)"')"
t_assert_eq "HIT" "$(_dedup_probe '\*(AArch64|X86-64|RISC-V)\*' \
  '              aarch64:*AArch64*|x86_64:*X86-64*|riscv64:*RISC-V*)')"
# …and must NOT flag the lines that legitimately survive.
t_assert_eq "MISS" "$(_dedup_probe 'head -c ?4.*tail -c ?3' \
  'magic="$(head -c4 "${wasm}" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d " \n")"')"
t_assert_eq "MISS" "$(_dedup_probe 'present at .*\(cross build — .* skipped\)' \
  'pass "onnxruntime_genai library present (cross build — import skipped)"')"
t_assert_eq "MISS" "$(_dedup_probe 'present at .*\(cross build — .* skipped\)' \
  'pass "opencv Python bindings present at ${p} (import skipped: foreign-arch extension under cross build — validated on-target by the runtime smoke)"')"

t_case "every smoke script that uses a helper also sources smoke-common.sh"
# The helpers are only defined by that source line; a script that grew a call
# without it would die with "command not found" inside a container RUN.
for _f in $(_dedup_scan 'smoke_(resolve_bin|is_elf|deferred_if_elf|cross_presence_gate|elf_machine_of)' \
            | cut -d: -f1 | sort -u); do
  t_assert_ok grep -q 'source "${_SCRIPT_DIR}/smoke-common.sh"' "${_SMOKE_DIR}/${_f}"
done

t_summary
