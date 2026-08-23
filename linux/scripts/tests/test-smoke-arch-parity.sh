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
# the reviewed record of the deltas (riscv64 has no CMake archive upstream, no
# riscv64 genai wheel exists). Scope, stated precisely because the earlier
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
# Parse the case arms of _parity_exempt: "<arch>:<component>)".
_tracked="$(_rt_table 'printf "%s %s" "${_PARITY_PREFIXES}" "${_PARITY_WHEELS}"')"
_orphans=""
while IFS= read -r _arm; do
  _comp="${_arm#*:}"
  case " ${_tracked} " in
    *" ${_comp} "*) ;;
    *) _orphans="${_orphans} ${_arm}" ;;
  esac
done < <(sed -n 's/^[[:space:]]*\(amd64\|arm64\|riscv64\):\([A-Za-z0-9_.+-]*\)).*/\1:\2/p' "${RT_SMOKE}" \
         | grep -v ':libgst')
t_assert_eq "" "${_orphans}" "exemption(s) for components the parity table does not track (dead entries)"

t_case "_parity_exempt only exempts what it documents"
t_assert_ok   _rt_table '_parity_exempt riscv64 cmake'
t_assert_ok   _rt_table '_parity_exempt riscv64 onnxruntime_genai'
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
exec env GST_PLUGIN_PATH=/fake/gst VULKAN_SDK=/fake/vulkan bash -s
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

# $1 = arch, $2 = installed genai version, $3 = optional uv.lock path.
# Default: no uv.lock, which isolates the build-pin path. Pass a lock to
# exercise the AUTHORITY rule itself (see the lock-vs-pin case below).
_stv_drive() {
  env -i PATH="${PATH}" HOME="${HOME}" \
    VENV="${_STV}/venv" VERSIONS_ENV="${_STV}/versions.env" \
    APP_UV_LOCK="${3:-${_STV}/no-such.lock}" STV_ARCH="$1" STV_CV2_REQUIRED=0 \
    STUB_TORCH=2.13.0+cpu STUB_TORCHVISION=0.28.0+cpu STUB_ONNXRUNTIME=1.29.0 \
    STUB_NUMPY=2.5.1 STUB_PIL=11.0.0 STUB_CONTOURPY=1.3.0 \
    STUB_AI_EDGE_LITERT=1.5.0 STUB_ONNXRUNTIME_GENAI="$2" \
    bash -c "source '${_STV}/stv.sh' >/dev/null 2>&1; FAILURES=0; assert_pinned_versions 2>&1; echo \"FAILURES=\${FAILURES}\""
}

t_case "the arm64 genai case is TOLERATED, loudly, and does not block the release"
_stv_out="$(_stv_drive arm64 0.14.0)"
t_assert_contains "${_stv_out}" "FAILURES=0"
t_assert_contains "${_stv_out}" "TOLERATED DRIFT"
t_assert_contains "${_stv_out}" "GENAI-DRIFT"
t_assert_contains "${_stv_out}" "1 TOLERATED DRIFT(s)"

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

t_case "KNOWN_DRIFT is one line per case, and only the reviewed case is in it"
# Deleting that single line must be all it takes to re-arm the assert.
_kd="$(sed -n '/^KNOWN_DRIFT = \[/,/^\]/p' "${TESTS_DIR}/../06-packaging/smoke-torch-venv.sh" \
        | grep -c '^    ("' || true)"
t_assert_eq "1" "${_kd}" "KNOWN_DRIFT grew: every entry needs its own review, date and backlog item"
t_assert_contains "$(sed -n '/^KNOWN_DRIFT = \[/,/^\]/p' "${TESTS_DIR}/../06-packaging/smoke-torch-venv.sh")" \
  "2026-08-23"

t_summary
