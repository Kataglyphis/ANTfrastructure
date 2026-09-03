# IREE: the two-stage cross build

`05-frameworks/torch/build-app-wheelhouse.sh` builds IREE for riscv64 in two
stages. Both carry hard-won configuration whose reasons are recorded here rather
than inline, so the code stays readable.

## Stage 1 — the native amd64 host tools

Stage 1 — NATIVE amd64 host build that populates IREE_HOST_BIN_DIR.
This function runs inside the riscv64 cross environment, where
CC/CXX/*FLAGS/CMAKE_TOOLCHAIN_FILE all point at the riscv64 cross toolchain
(set up for the torch build). The host tools MUST be native or they can't
execute on the build host to drive the target build — the first run
(2026-07-14) failed here precisely because the host cmake inherited the cross
CC/CXX. So strip the cross env for BOTH the configure and the build, and pin
the host compiler + both Python executables (FindPython/FindPython3 disagreed
on the first run).

IREE_BUILD_COMPILER=OFF here (2026-08-26). It used to be ON, which made this
stage compile IREE's bundled llvm-project + MLIR + Clang + LLD + stablehlo +
torch-mlir natively — the multi-hour "IREE" tail that live sampling caught
compiling clang/Basic/Targets/ARM.cpp and TargetInfo.cpp. That was a leftover
from the era when the TARGET stage was runtime-only (BUILD_COMPILER=OFF), the
configuration of incident run iree-0714c: back then tools/CMakeLists.txt's
if(IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER)
iree_import_binary(NAME iree-tblgen OPTIONAL) ... llvm-link ... clang
branch DID fire and the target really did need llvm-link/clang from the host.
CORRECTION 2026-09-02: this paragraph claimed the target stage sets
-DIREE_BUILD_COMPILER=ON. It does NOT — build-app-wheelhouse.sh passes
${IREE_CROSS_BUILD_COMPILER:-OFF}, and the section further down explains exactly
why ON is wrong for the target (its own iree-tblgen is built FOR THE TARGET ARCH
and then executed: "Exec format error"). So the import branch DOES fire, the
target DOES need iree-tblgen from the host, and COMPILER=OFF never installs it —
which made the host stage's OFF pass a guaranteed-wasted full build before the
escalation to ON. The host stage now asks for ON directly whenever the target is
OFF, and only requires the two LLVM-free tools when the target is ON.

The rest of this paragraph describes the ON-target case, which remains accurate
for that configuration: with the target on ON that branch is gated OFF and
IREE_CLANG_BINARY / IREE_LLVM_LINK_BINARY resolve to the target build's own
bundled-LLVM targets ($<TARGET_FILE:clang>, $<TARGET_FILE:llvm-link>,
build_tools/cmake/iree_llvm.cmake:83-85), never to IREE_HOST_BIN_DIR.

With the target on COMPILER=ON, a full grep of IREE v3.11.0 shows exactly TWO
places that read a file out of ${IREE_HOST_BIN_DIR}:
build_tools/cmake/iree_c_embed_data.cmake:97-98   iree-c-embed-data
build_tools/cmake/flatbuffer_c_library.cmake:90-91 iree-flatcc-cli
Both are tiny host codegen utilities with ZERO LLVM dependency (a single .cc,
and the flatcc CLI); both are added unconditionally (CMakeLists.txt:1049 and
:1141, neither EXCLUDE_FROM_ALL) and both `install(... RUNTIME DESTINATION
bin)` regardless of IREE_BUILD_COMPILER. Upstream's own cross script
build_tools/cmake/build_riscv.sh likewise runs `--target install` with
-DIREE_BUILD_COMPILER=OFF, so the COMPILER=OFF install path is the supported
one. Everything else that touches IREE_HOST_BIN_DIR is either the gated
iree_import_binary branch above or tests/samples (BUILD_TESTS=OFF,
BUILD_SAMPLES=OFF).

Guarded, not assumed: after the install we require both tools to exist.

The ON arm is insurance against exactly ONE risk — our reading of IREE's
cmake being wrong about those two tools installing under COMPILER=OFF.
It is NOT a general retry, and the earlier claim here that it costs "one
cheap extra pass" was false: ON is the multi-hour bundled-LLVM build this
change exists to avoid. ON's build graph is a strict SUPERSET of OFF's,
so anything that breaks the OFF *build* (bad host toolchain, OOM at
MAX_JOBS, no disk) breaks ON too, hours later, and the image fails
anyway. Hence the three outcomes are treated differently:
configure fails -> escalate (cheap, and could be OFF-path-specific)
BUILD fails     -> fail fast (ON cannot succeed where OFF could not)
tools missing   -> escalate (this is the case ON actually covers)

Returns 1 when neither COMPILER mode produced usable host tools.

## Stage 2 — cross the runtime and the Python bindings

Stage 2 — cross the runtime (+ Python bindings) against the host tools.
IREE_ENABLE_WERROR_FLAG=OFF is REQUIRED here (iree-0714g): the nanobind Python
bindings pull in the cross Python 3.14 pyconfig.h, which defines _POSIX_C_SOURCE/
_XOPEN_SOURCE to OLDER values than resolute's glibc features.h (already included
via <optional>/<cstdint> in binding.h) — a benign macro redefinition that IREE's
default -Werror turns fatal. Dropping -Werror keeps it a warning and lets the
riscv64 iree_base_runtime wheel build. (Python.h-include-order can't be fixed from
our side without patching IREE headers.)
IREE_OUTPUT_FORMAT_C=OFF is REQUIRED here (iree-0714m). It is a
cmake_dependent_option that defaults ON whenever IREE_BUILD_COMPILER=ON
(CMakeLists.txt:517), enabling the EmitC "vm-c" output format. That pulls in
runtime/src/iree/vm/test/emitc/CMakeLists.txt, which is gated on
IREE_OUTPUT_FORMAT_C (NOT IREE_BUILD_TESTS — so TESTS=OFF does not stop it) and
generates VM headers by RUNNING iree-compile at build time. With COMPILER=ON on
the TARGET, the tool name 'iree-compile' resolves to the just-built riscv64
binary, not the host tool in IREE_HOST_BIN_DIR, so the codegen tries to execute
a riscv64 iree-compile on the amd64 host and dies with
'libIREECompiler.so: cannot open shared object file' (code 127). Turning the
format OFF removes the only build-time consumer of the target compiler; the
riscv64 libIREECompiler.so + iree-compile still build (so the iree_base_compiler
wheel is intact), it just loses the niche vm-c/C-source output — standard .vmfb
bytecode compilation, which the app's check_iree uses, is unaffected.
CROSS TARGET IS RUNTIME-ONLY (2026-08-27, restored). IREE_BUILD_COMPILER
is OFF here, and that is not a preference -- it is the only configuration
upstream supports for a cross target.

IREE imports host tools only under
if(IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER)  (tools/CMakeLists.txt)
so with COMPILER=ON the target IGNORES IREE_HOST_BIN_DIR entirely, builds
its own iree-tblgen FOR THE TARGET ARCH, and then runs it during the build:
/.../iree-build-target/tools/iree-tblgen: Exec format error
FAILED: [code=126] .../Dialect/VM/IR/VMOpEncoder.cpp.inc
Proven NOT to be a host-side problem: the host stage completed with
COMPILER=ON and reported "tools present: iree-c-embed-data iree-flatcc-cli
iree-tblgen", and the target still used its own. Upstream's build_riscv.sh
sets the target to COMPILER=OFF for exactly this reason. The same class is
already documented below for iree-compile (IREE_OUTPUT_FORMAT_C=OFF).

WHAT THIS COSTS, plainly: arm64 and riscv64 ship the IREE RUNTIME wheel but
NOT iree_base_compiler. Commit 9b238e7 wanted both on cross; it set the flag
without providing a native tblgen, and that configuration cannot build.
amd64 is NATIVE, never enters this branch, and keeps both wheels.
IREE_CROSS_BUILD_COMPILER=ON re-tries it once IREE supports the combination.

Sets toolchain_file/iree_target_triple/cmake_args/iree_wheel_projects and
leaves the target-Python sysconfig exported for wheel packing. See docs/refactoring-backlog-archive-2026-08-31.md

## Why this page exists

Every paragraph above was originally an inline comment. They record incident runs
(`iree-0714c`, `iree-0714g`, `iree-0714m`) and precise upstream line references —
information that exists nowhere else — but at 100 lines they buried the code they
annotated. The code now carries a pointer to this page.

### Torch cross-wheel staging

---------------------------------------------------------------------------
IREE (iree.dev) compiler + runtime wheels — REQUIRED on every arch (see main()).

PyPI ships iree-base-{compiler,runtime} cp312-abi3 wheels for x86_64+aarch64
only; riscv64 has none, and we need version-specific cp314 everywhere, so we
source-build both wheels here. IREE cross-builds in two stages
(https://iree.dev/building-from-source/riscv/):
1. a HOST build producing the tools referenced via IREE_HOST_BIN_DIR, and
2. a TARGET build that cross-compiles the compiler + runtime + their Python
bindings against those host tools.
The TARGET stage is runtime-only by default (`IREE_CROSS_BUILD_COMPILER:-OFF`),
and that is what decides the host stage. IREE imports host tools only under
`if(IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER)` (tools/CMakeLists.txt), so a
COMPILER=OFF target DOES take that branch and needs `iree-tblgen` from the host —
three tools in total, with `iree-c-embed-data` and `iree-flatcc-cli`. A
COMPILER=OFF host build never installs tblgen, so the host stage asks for
**`IREE_BUILD_COMPILER=ON` directly**. Set `IREE_CROSS_BUILD_COMPILER=ON` and the
target ships the `iree_base_compiler` wheel too; then the import branch is not
taken and two host tools suffice.

Failure handling: build_iree_wheels returning non-zero is FATAL in main() —
IREE is required on every arch — so each stage dumps its log tail before
returning. This cannot be validated on the amd64 dev host.

Split into _iree_* stages sharing build_iree_wheels' locals by dynamic scope;
per-helper contracts in docs/refactoring-backlog-archive-2026-08-31.md.

### The host tools stage 2 needs from IREE_HOST_BIN_DIR

Tools the target stage needs from IREE_HOST_BIN_DIR.

iree-tblgen IS REQUIRED HERE (regression fix 2026-08-27). The original
list held only the two LLVM-free codegen helpers, on the reading that
tools/CMakeLists.txt gates host-tool imports behind
`IREE_HOST_BIN_DIR AND NOT IREE_BUILD_COMPILER` and our target sets
COMPILER=ON, so nothing else is imported. That is true -- and it is
exactly the problem: nothing being imported means the TARGET build
builds its own iree-tblgen, FOR THE TARGET ARCH, and then tries to RUN
it during the build. On a cross lane that is an arm64 binary on an
amd64 host:
/…/iree-build-target/tools/iree-tblgen: Exec format error
FAILED: [code=126] …/VMOpEncoder.cpp.inc
It cannot show up on amd64, where host and target are the same arch --
which is why the amd64 media stage passed cleanly and arm64 died.

Because a COMPILER=OFF host build can never install tblgen, probing OFF
first is a guaranteed miss: a complete host build, discarded, then redone
with ON. That cost two full host builds in the 2026-09-02 run, so the
default path now requests ON immediately and `host_compiler_modes` holds
just `(ON)`. The cost is that CROSS lanes build the bundled LLVM in the
host stage. If upstream ever installs tblgen without the compiler, restore
the `(OFF ON)` list and the saving returns.

### Wheel packing and the target Python sysconfig

64G, not 25G: IREE builds TWO full LLVM object sets (native host tools +
the target cross-LLVM), which together overflow a 25G cache and evict each
other (0714p thrashed — app-wheelhouse took 3.5h with a warm-but-too-small
cache). 64G comfortably holds both so reruns actually hit.
MEASURED 2026-08-26 (wave7e, riscv64): this used to read
`${CCACHE_MAXSIZE:-64G}` — but Dockerfile.base:87 already exports
CCACHE_MAXSIZE=30G, so `:-` NEVER applied the 64G this comment
promises, and the two LLVM object sets evicted each other exactly as
warned. Live evidence from the riscv64 lane: "Cacheable calls 42888
(95%), Hits 28319 (66%), cache size limit 30.0 GB" — every third
compile a MISS, which is why the bundled-LLVM build stayed a ~7-9h
cost per run instead of becoming one-time. Two fixes, both needed:
(1) override UNCONDITIONALLY (IREE_CCACHE_MAXSIZE is the escape
hatch, not the inherited base value), and (2) actually APPLY it —
the on-disk limit lives in the cache's own config and only changes
via `ccache -M`; exporting the env var alone leaves a 30G cache 30G.
2026-09-02 follow-up: with the target runtime-only (the default), the HOST
stage runs COMPILER=ON and builds the bundled LLVM, so TWO full LLVM object
sets — host and target cross — plus the riscv64 torch aten objects compete
for this cache. 64G is kept deliberately: it is now generous
rather than merely sufficient, which is what makes reruns hit.
