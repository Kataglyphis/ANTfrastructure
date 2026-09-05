#!/usr/bin/env bash
# test-genai-smoke-payload.sh — drives the GEN1 payload (smoke-common.sh
# smoke_genai_py + its six per-tier emitters) as a standalone program.
#
# The payload only ever runs inside a foreign-arch runtime image, so nothing
# else in the tree can see it fail. What is pinned here is the contract
# check_genai_binding depends on: the GENAI-BIND/GENAI-GEN sentinels, the
# 0/1/3 exit codes, and the three verdicts that were hand-checked when the
# code was written — absent -> SKIP(3), installed-but-unimportable -> FAIL(1),
# working binding -> OK(0). docs/gen1-riscv64-genai.md, docs/failure-modes.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE_COMMON="${TESTS_DIR}/../06-packaging/smoke-common.sh"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# smoke-common.sh sets -euo pipefail, so it is loaded in a SUBSHELL.
_emit() { bash -c "source '${SMOKE_COMMON}'; $1"; }

PROG="${_WORK}/genai_smoke.py"
_emit smoke_genai_py > "${PROG}"

# ── A. the decomposition itself ─────────────────────────────────────────────
# Each tier must be separately emittable, and the concatenation must be the
# whole program — otherwise a tier can silently drop out of the payload.
# Byte-level, via files: command substitution eats the blank line each tier
# ends with, and that blank line is part of the program.
_TIERS=(preamble tier1_version tier2_elf tier3_native tier4_generate verdict)
: > "${_WORK}/concat.py"
for _t in "${_TIERS[@]}"; do
  t_case "emitter _smoke_genai_py_${_t} produces a non-empty fragment"
  _emit "_smoke_genai_py_${_t}" > "${_WORK}/frag.py"
  t_assert_ok test -s "${_WORK}/frag.py"
  cat "${_WORK}/frag.py" >> "${_WORK}/concat.py"
done
t_case "smoke_genai_py is byte-for-byte the six tier emitters, in order"
t_assert_ok cmp -s "${_WORK}/concat.py" "${PROG}"

t_case "the emitted payload is syntactically valid Python"
t_assert_ok python3 -c "import sys;compile(open(sys.argv[1]).read(),sys.argv[1],'exec')" "${PROG}"

t_case "each tier is anchored by its own sentinel/marker (tiers cannot be silently gutted)"
t_assert_contains "$(_emit _smoke_genai_py_preamble)"      "GENAI-BIND SKIP"
t_assert_contains "$(_emit _smoke_genai_py_preamble)"      "INSTALLED but not importable"
t_assert_contains "$(_emit _smoke_genai_py_tier1_version)" "GENAI_EXPECT_VERSION"
t_assert_contains "$(_emit _smoke_genai_py_tier2_elf)"     "e_machine"
t_assert_contains "$(_emit _smoke_genai_py_tier3_native)"  "og.Tensor"
t_assert_contains "$(_emit _smoke_genai_py_tier4_generate)" "GENAI_MODEL_DIR"
t_assert_contains "$(_emit _smoke_genai_py_verdict)"       "GENAI-BIND OK:"

# ── fixtures ────────────────────────────────────────────────────────────────
EMPTY="${_WORK}/empty"; mkdir -p "${EMPTY}"

# A stub that behaves like a healthy binding: version, a loaded native
# extension, the pybind names, capability predicates, Tensor, Config.
STUB="${_WORK}/stub"; mkdir -p "${STUB}/onnxruntime_genai" "${STUB}/numpy"
t_fake_elf "${STUB}/onnxruntime_genai/ext_x86_64.so" 62
t_fake_elf "${STUB}/onnxruntime_genai/ext_riscv64.so" 243
cat > "${STUB}/onnxruntime_genai/__init__.py" <<'PY'
import os, sys, types
__version__ = os.environ.get("STUB_GENAI_VERSION", "0.15.2")
_ext = types.ModuleType("onnxruntime_genai.onnxruntime_genai")
_ext.__file__ = os.environ.get("STUB_GENAI_EXT", "")
sys.modules[__name__ + ".onnxruntime_genai"] = _ext
onnxruntime_genai = _ext
class Tensor:
    def __init__(self, arr): self._a = arr
    def shape(self): return [1, 4]
    def as_numpy(self): return self._a
class Config:
    def __init__(self, path): raise RuntimeError("stub: %s is not a model" % path)
class Model:
    def __init__(self, path): raise RuntimeError("stub: no weights")
class Tokenizer: pass
class GeneratorParams: pass
class Generator: pass
def is_cuda_available(): return False
def is_webgpu_available(): return False
def is_qnn_available(): return False
for _n in os.environ.get("STUB_GENAI_DROP", "").split(","):
    if _n:
        globals().pop(_n, None)
PY
# Minimal numpy so tier 3's Tensor round-trip is ARMED (the host has no numpy;
# without this the tier reports UNPROVEN and proves nothing).
cat > "${STUB}/numpy/__init__.py" <<'PY'
float32 = "float32"
class _Arr:
    def __init__(self, d): self._d = d
    def tolist(self): return self._d
def array(data, dtype=None):
    return _Arr([[float(x) for x in row] for row in data])
PY

# Installed-but-unimportable: the DISTRIBUTION metadata is present, the import
# blows up. This must be a FAIL, never a SKIP. docs/failure-modes.md
BROKEN="${_WORK}/broken"
mkdir -p "${BROKEN}/onnxruntime_genai" "${BROKEN}/onnxruntime_genai-0.15.2.dist-info"
printf 'raise ImportError("libonnxruntime-genai.so: undefined symbol: Oga_stub")\n' \
  > "${BROKEN}/onnxruntime_genai/__init__.py"
printf 'Metadata-Version: 2.1\nName: onnxruntime-genai\nVersion: 0.15.2\n' \
  > "${BROKEN}/onnxruntime_genai-0.15.2.dist-info/METADATA"

# Run the payload the way the image does: piped into `python -`.
# -S keeps host site-packages out, so PYTHONPATH is the whole world here.
_run() {  # $1 = PYTHONPATH, rest = VAR=VAL ...
  local pp="$1"; shift
  _OUT="$(env -u GENAI_MODEL_DIR -u GENAI_EXPECT_VERSION -u GENAI_EXPECT_ARCH \
            PYTHONPATH="${pp}" PYTHONDONTWRITEBYTECODE=1 "$@" \
            python3 -S - < "${PROG}" 2>&1)"
  _RC=$?
  return 0
}

# ── B. the three hand-verified verdicts ─────────────────────────────────────
t_case "module absent -> GENAI-BIND SKIP, rc=3"
_run "${EMPTY}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64
t_assert_eq "3" "${_RC}"
t_assert_contains "${_OUT}" "GENAI-BIND SKIP: onnxruntime_genai is not installed"

t_case "distribution INSTALLED but unimportable -> GENAI-BIND FAIL, rc=1 (never a SKIP)"
_run "${BROKEN}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "GENAI-BIND FAIL: onnxruntime_genai 0.15.2 is INSTALLED but not importable"
t_assert_ok test -z "$(printf '%s' "${_OUT}" | grep -c 'GENAI-BIND SKIP' | grep -v '^0$')"

t_case "a correct binding -> GENAI-BIND OK, rc=0, with all four tiers reported"
_run "${STUB}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64 \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so"
t_assert_eq "0" "${_RC}"
t_assert_contains "${_OUT}" "GENAI-BIND OK: onnxruntime_genai 0.15.2"
t_assert_contains "${_OUT}" "PROVEN   __version__ 0.15.2 matches the build pin"
t_assert_contains "${_OUT}" "is X86-64 ELF (e_machine=62)"
t_assert_contains "${_OUT}" "og.Tensor round-tripped a float32 buffer"
t_assert_contains "${_OUT}" "og.Config() rejected a non-model path from native code"
t_assert_contains "${_OUT}" "GENAI-GEN SKIP: no GENAI_MODEL_DIR set"

# ── C. each tier can actually fail ──────────────────────────────────────────
t_case "tier 1: version != the versions.env pin -> FAIL rc=1"
_run "${STUB}" GENAI_EXPECT_VERSION=0.14.0 GENAI_EXPECT_ARCH=amd64 \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so"
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "version 0.15.2 != versions.env pin 0.14.0"

t_case "tier 1: no GENAI_EXPECT_VERSION is UNPROVEN, not a pass claim"
_run "${STUB}" GENAI_EXPECT_ARCH=amd64 \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so"
t_assert_eq "0" "${_RC}"
t_assert_contains "${_OUT}" "UNPROVEN version (no GENAI_EXPECT_VERSION passed in)"

t_case "tier 2: a host-arch .so in a riscv64 image -> FAIL rc=1"
_run "${STUB}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=riscv64 \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so"
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "has ELF machine 62, expected 243 (RISC-V) for riscv64"

t_case "tier 2: the right .so for riscv64 passes"
_run "${STUB}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=riscv64 \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_riscv64.so"
t_assert_eq "0" "${_RC}"
t_assert_contains "${_OUT}" "is RISC-V ELF (e_machine=243)"

t_case "tier 2: an unreadable extension is a sentinelled FAIL, not an escaping OSError"
_run "${STUB}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64 \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai"
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "cannot read the loaded extension"
t_assert_contains "${_OUT}" "GENAI-BIND FAIL:"
t_assert_ok test -z "$(printf '%s' "${_OUT}" | grep -c 'Traceback' | grep -v '^0$')"

t_case "tier 2: a non-ELF extension -> FAIL rc=1"
printf 'not an elf at all, just text padding\n' > "${_WORK}/notelf.so"
_run "${STUB}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64 \
     STUB_GENAI_EXT="${_WORK}/notelf.so"
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "is not an ELF object"

t_case "tier 3: a pybind module missing a documented name -> FAIL rc=1"
_run "${STUB}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64 \
     STUB_GENAI_DROP=Generator STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so"
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "og.Generator missing"

t_case "tier 3: Config refused at the BINDING layer (TypeError) -> FAIL rc=1"
# Dropping Config's ctor arg is exactly the ABI/signature mismatch shape.
BINDBAD="${_WORK}/bindbad"; mkdir -p "${BINDBAD}"
cp -r "${STUB}/onnxruntime_genai" "${STUB}/numpy" "${BINDBAD}/"
printf '\nclass Config:\n    def __init__(self): pass\n' >> "${BINDBAD}/onnxruntime_genai/__init__.py"
_run "${BINDBAD}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64 \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so"
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "og.Config() failed at the BINDING layer"

t_case "tier 4: GENAI_MODEL_DIR pointing at a non-directory -> FAIL rc=1"
_run "${STUB}" GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64 \
     GENAI_MODEL_DIR=/nonexistent-genai-model \
     STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so"
t_assert_eq "1" "${_RC}"
t_assert_contains "${_OUT}" "GENAI_MODEL_DIR=/nonexistent-genai-model is not a directory"

# ── D. the SMOKE_GENAI_PY injection path ────────────────────────────────────
# check_genai_binding ships the program through an env var and pipes it into
# `python -`; that boundary is how it reaches images built before the check
# existed, and an empty crossing is exit 4 upstream. Pin both halves.
t_case "the program survives the SMOKE_GENAI_PY env-var round trip with the same verdict"
_INJ_OUT="$(env -u GENAI_MODEL_DIR PYTHONPATH="${STUB}" PYTHONDONTWRITEBYTECODE=1 \
  GENAI_EXPECT_VERSION=0.15.2 GENAI_EXPECT_ARCH=amd64 \
  STUB_GENAI_EXT="${STUB}/onnxruntime_genai/ext_x86_64.so" \
  SMOKE_GENAI_PY="$(_emit smoke_genai_py)" \
  bash -lc 'if [ -z "${SMOKE_GENAI_PY:-}" ]; then
  echo "GENAI-BIND ABSENT: SMOKE_GENAI_PY is empty inside the container -- the program never crossed the boundary"
  exit 4
fi
printf "%s\n" "${SMOKE_GENAI_PY}" | python3 -S -' 2>&1)"
_INJ_RC=$?
t_assert_eq "0" "${_INJ_RC}"
t_assert_contains "${_INJ_OUT}" "GENAI-BIND OK: onnxruntime_genai 0.15.2"

t_case "an empty SMOKE_GENAI_PY is the ABSENT sentinel with rc=4, never a silent pass"
_INJ_OUT="$(SMOKE_GENAI_PY="" bash -lc 'if [ -z "${SMOKE_GENAI_PY:-}" ]; then
  echo "GENAI-BIND ABSENT: SMOKE_GENAI_PY is empty inside the container -- the program never crossed the boundary"
  exit 4
fi
printf "%s\n" "${SMOKE_GENAI_PY}" | python3 -S -' 2>&1)"
_INJ_RC=$?
t_assert_eq "4" "${_INJ_RC}"
t_assert_contains "${_INJ_OUT}" "GENAI-BIND ABSENT:"


# DRIFT GUARD. The cases above run a hand-copied replica of the wrapper in
# check_genai_binding, so a change to the real one would not fail them.
# Mutation-proven: renaming the real ABSENT sentinel left the suite green.
t_case "the replica above still matches check_genai_binding's real wrapper"
_SRI="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"
# grep -F -e, not t_assert_contains: the haystack is a whole file and a failure
# message must not print it. The -e is load-bearing (host grep is ugrep).
# Extract just check_genai_binding's wrapper: the file has a second `exit 4`
# elsewhere, so a whole-file grep would stay green while this one rotted.
_WRAP="$(sed -n '/SMOKE_GENAI_PY:-/,/python -.$/p' "${_SRI}")"
t_assert_contains "${_WRAP}" "GENAI-BIND ABSENT:" "wrapper lost its ABSENT sentinel"
t_assert_contains "${_WRAP}" "exit 4" "wrapper no longer exits 4 on an empty payload"

t_summary
