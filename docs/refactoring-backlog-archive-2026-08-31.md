# Refactoring backlog — CLOSED 2026-08-31 (A1 closure window + GEN1)

> Split out of [`refactoring-backlog.md`](refactoring-backlog.md) so that file
> shows only OPEN work. Nothing here needs action; it is kept because the
> entries record WHY a thing is the way it is — including two closed by being
> REFUTED rather than fixed, the kind of finding that gets re-discovered if the
> reasoning disappears. Earlier rounds:
> `refactoring-backlog-archive-2026-08-10.md`,
> `refactoring-backlog-archive-2026-08-27.md`,
> `refactoring-backlog-archive-2026-08-30.md`.

Full narrative in CHANGELOG.md (2026-08-31, "Linux backlog closure window").
Gates at closure: `make lint` clean (276 files), `make preflight` green,
`make test-linux-scripts` 38 suites / 1001 assertions. **No container build
was run** — everything here is static-gate-proven only.

## Closed on 2026-08-31

- ✅ **logging.sh ERR-trap dynamic-scope bug — FIXED.** `_install_trap`'s
  `on_err` read the reporting action from the installer's `local action` via
  dynamic scope; the trap fires long after the installer returns, so under
  `set -u` the handler died with `action: unbound variable`, REPLACING the real
  error (it masked the 2026-08-30 parallel-GCC apt-lock failure) and never
  running `err`/`warn` at all. `on_err` is now top-level and the action is baked
  into the trap string via `printf -v '%q'`, with `LINENO`/`BASH_COMMAND` still
  expanding AT FIRE TIME. `_LOG_TRAP_ACTION` exists for `build-gcc.sh:709`,
  which re-arms the BARE trap string by hand after `trap - ERR` — a caller the
  original brief did not know about. Regression suite
  `tests/test-logging-err-trap.sh` (30 assertions) verified to fail 29/30
  against the pre-fix file.
  NB behaviour note: inside a `set +e` window `install_err_trap` now EXITS 1
  where it used to print noise and continue. No current caller has such a
  window (checked repo-wide); this is the documented intent, but it is a real
  change if one is ever added.

- ✅ **Complexity-queue survivors — DONE.** (`_cross_stage_build_impl` was
  already a single impl behind two thin wrappers, closed 2026-08-30 — do NOT
  re-add it to this queue.) `append_tvm_cmake_args` 15
  positionals → named options (both call sites, `tvm.sh` + `tvm-python.sh`,
  with golden-value tests asserting the emitted array is byte-identical);
  `_build_vulkan_targets` (137 lines) and `_llvm_cross_setup_and_build`
  (146 lines) decomposed along real seams; `build_iree_wheels` split into nine
  `_iree_*` stages; `base-image.sh parse_options` (116-line nested case/while)
  collapsed to a data table preserving the `--ports-url` `${2-}` vs
  `--archive-url` `${2:-}` empty-vs-unset asymmetry, the
  `install-vulkan-runtime-files` `--`/`-*`/`*` passthrough with its
  `REMAINING_ARGS`, and every die-message string verbatim.

#### `append_tvm_cmake_args` — the keyword contract

`linux/scripts/05-frameworks/tvm-config.sh`. Appends TVM's `-D` flags to the
caller's array, which is passed **by name** (nameref). Options are keywords,
not positions: the predecessor took 15 positionals of which the last six were
optional-with-defaults, so a dropped or transposed argument produced a silently
WRONG feature set that surfaced only hours into the build — or, worse, as a
mis-featured shipped wheel. An unknown option is now a hard `die`.

Required — must be PRESENT, though the value may legitimately be empty:

| Option | Effect |
| --- | --- |
| `--out ARRAY` | name of the caller's array to append to |
| `--python-module` | `ON`/`OFF` → `-DTVM_BUILD_PYTHON_MODULE` |
| `--build-type` | `-DCMAKE_BUILD_TYPE` |
| `--cc` / `--cxx` | `-DCMAKE_C_COMPILER` / `-DCMAKE_CXX_COMPILER` |
| `--llvm-cmake-value` | `-DUSE_LLVM` (an `llvm-config` path, `ON`, or `OFF`) |
| `--llvm-dir` | `-DLLVM_DIR`; empty means "let TVM search" |
| `--llvm-ignore-paths` | `-DCMAKE_IGNORE_PATH`, honoured only alongside `--llvm-dir` |
| `--use-vulkan` | `0`/`1` |

Optional, with defaults: `--use-cuda` (0), `--use-opencl` (0),
`--spirv-tools-lib` (empty), `--cross-link-flags` (empty), `--vulkan-library`
(empty), `--vulkan-include` (empty).

Two implementation details that are easy to undo by accident:

* **Every internal local is `_tvm_`-prefixed.** A nameref whose target resolves
  to a local of the same function is a circular reference; the old
  `out_ref` / `llvm_dir` / … names were in exactly that line of fire, since the
  caller's array name is arbitrary.
* **The presence loop over the nine formerly-mandatory positions** exists so a
  dropped option fails at the call, not as a wrong `-D` flag three hours into
  the compile. It tests `${_tvm_seen[$opt]+x}`, not `:-`, so an unset key is
  safe under `set -u` on bash 4.3 as well.

Both call sites (`tvm.sh`, `tvm-python.sh`) are covered by
`linux/scripts/tests/test-tvm-cmake-args.sh`, which asserts the emitted array is
byte-identical to the positional version's.

#### `base-image.sh parse_options` — the option table

`BASE_IMAGE_OPTION_SPECS` maps `"<command> <flag>"` to
`"<target-var>|<value-mode>|<side-effect>"`, and `base_image_apply_option`
applies one `<flag> <value>` pair or dies with the per-command unknown-argument
message. The value passed is the caller's `"${2-}"`, so an absent value
collapses to empty and every mode below handles that.

| value-mode | Meaning |
| --- | --- |
| `required` | value must be non-empty (`require_single_value`) |
| `optional` | an EMPTY value is legal and is assigned verbatim |
| `bool` | required, then validated/normalized by `parse_bool_flag` |

* The `--archive-url` / `--ports-url` asymmetry is REAL, not an oversight: an
  empty `--ports-url` is accepted and means "derive the ports mirror from the
  archive URL", while an empty `--archive-url` is a caller bug. Do not
  harmonize them.
* `bool` assigns **through the nameref** rather than via a temporary, so that
  when `parse_bool_flag` dies inside its command substitution the target lands
  empty and `set -e` ends the process — byte-for-byte what the pre-table
  `VAR="$(parse_bool_flag …)"` arm did.
* The single side effect any flag carries beyond its own assignment is
  `use-fast-mirror`: naming a mirror URL implies opting INTO the fast mirror.
* `install-vulkan-runtime-files` is the ONLY command that takes positionals. It
  stops at the first non-flag (or at an explicit `--`) and hands the rest to
  `install_vulkan_runtime_files` through `REMAINING_ARGS`, which no other
  command sets.

Covered by `linux/scripts/tests/test-base-image-parse-options.sh`.

  Three seam contracts the decomposed helpers now depend on, none of which is
  visible from a helper's own body — a later "cleanup" that breaks either one
  fails only in a multi-hour cross build:
  - **`vulkan.sh` — the `_vulkan_target_*` helpers.** They are the inline body
    of `_build_vulkan_targets` (copy headers → loader → SPIRV-Tools → glslang →
    verdict), and the split preserves two things. (1) Every call is a **plain
    statement** — never inside an `if`, a `&&` chain or a `$( )` — so `set -e`
    stays live inside the helper exactly as it was when the code was inline;
    moving one call into a condition would silently disable errexit for that
    whole helper. This is why `_vulkan_target_link_glslang_aliases` ends in an
    explicit `return 0`: its last statement is a `[ -e … ] && ln` loop whose
    test is false whenever the final name is absent, so without the `return`
    the helper exits non-zero and aborts the SDK stage. Inline, the next
    statement was the `_vk_ok=` assignment, which always reset `$?` to 0. A
    genuinely failing `ln` still aborts — errexit fires on it first.
    (2) They read the caller's `_xbuild_cc`/`_xbuild_cxx`/`_xbuild_proc` and
    update its `_vk_attempted`/`_vk_ok` counters by **dynamic scope** (the same
    contract `_cross_build_sdk_component` already carried). None of them may
    declare those five names `local`, and none is callable from outside
    `_build_vulkan_targets` — under `set -u` the counters would be unbound.
    The step ORDER in the caller is also a contract: headers before loader,
    because the loader build needs them. `tests/test-vulkan-target-decomposition.sh`
    pins the order, the per-component argv and the `return 0`.
  - **`llvm-cross.sh` — nameref name collisions.** The helpers take the state
    map and the out-arrays BY NAME and bind them with `local -n`. A nameref
    whose target has the same name is a bash circular reference, so the
    `_build_llvm_cross_core` state array must not be called `_r`, `_cfg` or
    `_bi` (the names the pre/post-build, configure and install helpers bind it
    with), and the same holds for the arrays passed to the
    `_llvm_cross_*_args` helpers. Getting it wrong turns every write into an
    "unbound variable". Separately, `_llvm_cross_cmake_configure` reads `CC`,
    `CXX`, `AR`, `CROSS_TARGET_*` and `CMAKE_SYSROOT` from the environment that
    `setup_linux_cross_env` exported into `_llvm_cross_setup_and_build`'s
    subshell, so it is only callable from inside that subshell.
    `tests/test-llvm-cross-stanza.sh` pins the injected arg groups' insertion
    points and the four build/install calls.
  - **`build-app-wheelhouse.sh` — the `_iree_*` stages.** The nine helpers are
    the inline body of `build_iree_wheels`, in pipeline order, and they follow
    the convention `_torch_run_setup_py` already used in that file: each one
    reads `build_iree_wheels`' locals through **dynamic scope**, and several
    write back into them, so none of those names may be declared `local` in a
    helper. Concretely:
    - `_iree_check_prereqs` sets `wheel_platform`.
    - `_iree_setup_compiler_cache` fills `ccache_cmake_args` and sets the global
      `_iree_launcher`, and `export`s the `CCACHE_*`/`SCCACHE_*` environment that
      every later build step relies on. It never fails. `ccache_cmake_args` is
      declared in the CALLER for exactly this reason: a `local -a` inside the
      helper would hide the array from the build stages below it.
    - `_iree_fetch_source` and `_iree_patch_setup_py_abi3` work on `src_dir`.
    - `_iree_append_qnn_cmake_args` appends to `cmake_args`.
    - `_iree_build_host_stage` reads `src_dir`, `host_build`, `host_install`,
      `host_cc`, `host_cxx` and `ccache_cmake_args`.
    - `_iree_build_target_cross` reads `src_dir`, `target_build`,
      `host_install`, `host_cc`, `host_cxx`, `cmake_args`, `ccache_cmake_args`
      and `_iree_launcher`; it sets `toolchain_file`, `iree_target_triple`,
      further `cmake_args` and `iree_wheel_projects`, and it deliberately leaves
      the exported TARGET-Python sysconfig (`_PYTHON_SYSCONFIGDATA_NAME`) in
      place, because the wheel-packing step still needs it.
    - `_iree_build_target_native` reads `src_dir`, `target_build` and
      `ccache_cmake_args`, and leaves `iree_wheel_projects` EMPTY so the
      packaging step defaults to both wheels — that empty default is what keeps
      the native path byte-identical to the pre-split code.
    - `_iree_package_wheels` reads `target_build`, `dist_dir` and
      `wheel_platform`, may default `iree_wheel_projects`, and is called LAST
      from `build_iree_wheels`, so ITS status is the function's status (there is
      no trailing `|| return 1` at that call site, and adding one is harmless
      but redundant).

    `host_cc`/`host_cxx` are resolved in the CALLER, not inside
    `_iree_build_host_stage`, because BOTH cross stages need them: stage 1 builds
    the host tools with them and stage 2 pins bundled LLVM's NATIVE tblgen
    sub-build to them via `CROSS_TOOLCHAIN_FLAGS_NATIVE`.

    Failure convention: every helper that can fail `return 1`s, and the caller
    turns that into its own `return 1` — i.e. skip IREE, never abort the
    wheelhouse mid-flight. (`build_iree_wheels` returning non-zero is then FATAL
    in `main()`, since IREE is required on every arch.)
    `tests/test-iree-wheelhouse-stages.sh` pins the call order and the
    `|| return 1` at each fallible call site.

- ✅ **modules.sh dir-walker — CLOSED by REFUTATION. Do not re-flag.**
  All four suspected defects were probe-tested and refuted: `_find_scripts_root`
  provably terminates for relative, absolute, dot-relative, empty and
  trailing-slash inputs and cannot cycle (the walk is lexical, so symlinks are
  irrelevant); the `return 1` signal IS consumed correctly, because a success
  path can never print an empty string (the `[ -n "$d" ]` guard), making
  `[ -n "${root}" ]` exactly equivalent to `rc == 0`; `BASH_SOURCE[1]` is the
  call-site file at ANY nesting depth (verified with a 3-deep cross-file chain),
  so the "wrong frame when nested" hypothesis is a misreading of the
  FUNCNAME/BASH_SOURCE pairing; and the space-joined `searched:` list is
  ambiguous only for paths with spaces, which cannot occur here. What remains is
  a while loop that looks like a while loop — in a file that is in the
  base/compiler/media cache closure and whose last mistake was an infinite
  re-source loop ending in SIGSEGV. Style churn here is a NET NEGATIVE.

- ✅ **IREE regression suite over-claimed its coverage — FIXED (toothless-gate
  class).** The new `test-iree-wheelhouse-stages.sh` header claimed a missing
  `|| return 1` at any call site would fail an assertion; only 2 of 5 sites were
  actually mutation-covered. Two compounding causes, both now recorded in the
  file: (1) the first fault-injection attempt silently did NOTHING because the
  host `grep` is **ugrep**, which parses a pattern beginning `--` as an option —
  fixed with `grep -qE -e`, with a comment saying why `-e` is load-bearing;
  (2) even with injection working, asserting `rc == 1` did not discriminate,
  because `_iree_package_wheels` bails at its own
  `[ ! -d "${target_build}/${_proj}" ]` guard and returns 1 anyway — the right
  answer for the wrong reason, and with "produced no runtime/ wheel project"
  replacing the real configure failure plus its 80-line log. The cases now also
  assert the PACKAGING diagnostic is ABSENT, which is what actually pins the
  early abort. All five call sites are now mutation-verified to fail ≥1
  assertion.

- ✅ **GEN1 — genai wheel for riscv64 — BUILT and WIRED ON** (user decision
  2026-08-31; the entry's "only if it has a user" gate was answered).
  riscv64 now takes the same cross path arm64 takes: the hard arch guard is
  gone and the cross allowlist is an explicit `arm64|riscv64`. Effort was far
  below the "L" estimate — the arm64 cross path was already arch-generic
  (`CROSS_TARGET_TRIPLET` / `CROSS_TARGET_PROCESSOR` / `CROSS_RUST_TARGET` /
  `cross_wheel_platform_tag`) and `platform.sh` already mapped riscv64
  completely (triplet, `riscv64gc-unknown-linux-gnu`, `linux_riscv64`, ELF
  `RISC-V`).
  - **One upstream blocker, one-hunk patch:**
    `patches/onnxruntime-genai/001-riscv64-target-platform.patch`.
    `cmake/target_platform.cmake`'s Linux branch `FATAL_ERROR`s on any processor
    that is not arm64/x64/powerpc — configure dies before a single object
    compiles. `genai_target_platform` is read ONLY under `WIN32`/`ENABLE_JAVA`/
    MSVC, so the added arm is inert everywhere else. Proven to apply and re-apply
    idempotently against a real clone of the pinned tag v0.15.2 (`ed5f4e87`).
    The rejected alternative (lying about `CMAKE_SYSTEM_PROCESSOR`) is recorded
    in [`gen1-riscv64-genai.md`](gen1-riscv64-genai.md), not shipped. (The patch
    file itself is 13 lines of pure diff, no comment block.)
  - `--use_guidance` KEPT on riscv64 — but note it is auto-DROPPED with only a
    WARN if a riscv64-only preflight finds rustup lacks the std, which ships a
    parity-divergent wheel no gate can see (watch item, section A1).
    (Rust Tier-2-with-host-tools; the crate
    graph Corrosion imports is pure Rust; `install-rust.sh` adds the std for
    every `CROSS_TARGETS` arch). Dropping it would have shipped a *different*
    wheel than amd64/arm64 that the parity table could not distinguish.
  - Escape hatch **`GENAI_ALLOW_RISCV64`** restores the pre-GEN1
    placeholder-and-skip exactly. TWO review defects fixed: it never reached the
    in-container smoke (`nerdctl run` inherits nothing, and the media *final*
    stage is `FROM media-inputs`, so the ARG/ENV on the `onnxruntime` builder
    stage is not in the shipped image) — now forwarded via `-e`; and producer
    (`:-false`) vs verifier (`:-true`) defaults disagreed in the FAILING
    direction, so the producer would skip and the verifier then hard-fail on the
    placeholder tree it had just created. The producer now drops a
    `.gen1-lane-off` marker and the verifier reads the producer's ACTUAL
    decision instead of re-deriving it.
  - `smoke_genai_py()` (in `smoke-common.sh`, runs on EVERY arch) asserts the
    version against the versions.env pin, that the loaded extension's ELF
    machine is the target's, and that the pybind API objects exist. A review
    defect was fixed here too: it conflated "no wheel on this arch" with "wheel
    installed but its native library will not load" — both exited 3 = benign
    SKIP, and every other gate is blind to the second case
    (`smoke-torch-venv`'s `installed_version()` falls back to
    `importlib.metadata` when the import raises; ARCH-PARITY only reads
    dist-info directory names). An installed-but-unimportable distribution is
    now a hard FAIL.

## Also closed 2026-08-31 (second pass, same window — the risk-REDUCING half of Section B)

Done deliberately BEFORE the rebuild: both make the rebuild more likely to catch
a real GEN1 failure instead of shipping it. The window was already open and no
build was running, so the cache cost was zero.

- ✅ **GenAI libraries were scanned by NOTHING — FIXED.**
  `validate-media-runtime.sh` checked unresolved `NEEDED` only over `ARTIFACTS`
  (the gst/libcamera/ffmpeg binaries) plus the gst plugin dir; its `LIB_DIRS`
  sweep checks ELF **machine** only and is advisory. `/usr/local/lib/onnxruntime-genai/lib`
  appeared in NEITHER list, so an unresolved `NEEDED` in
  `libonnxruntime-genai*.so` was invisible — exactly the documented riscv64
  `-latomic` risk (GenAI's CMake, unlike upstream ORT's, has no libatomic
  probe). Two changes: the prefix joins `LIB_DIRS` (resolution root + advisory
  arch sweep), and the lib dir is now walked by `scan_plugin_directory` —
  misnamed but generic, so it was reused rather than copied — feeding the
  existing `ALL_MISSING` repair/deny machinery. Guarded by `[ -d ]`, so it is a
  no-op when the lane is off and the placeholder tree has an empty `lib/`.
  amd64/arm64 are expected to resolve exactly as before because genai's own
  deps (`libonnxruntime.so` and friends) live in
  `/usr/local/lib/onnxruntime-cpu/lib`, already a `LIB_DIRS` root — **but this
  is a NEW gate on all three arches and has not been run against a real image.**

- ✅ **`prune_conflicting_onnx_wheels` deleted the wheel the same file needs —
  FIXED.** On the DEFAULT `ONNX_PACKAGE=onnxruntime` path it ran
  `rm -f /opt/wheels/*genai*.whl`, whose glob matches the CPU wheel
  `onnxruntime_genai-<ver>-…whl` that this media lane now builds on every arch —
  the very wheel `build_uv_sync_args` looks for 60 lines later, and that
  ARCH-PARITY now asserts must be installed. Ordering confirmed:
  `install_project_environment` prunes BEFORE `build_uv_sync_args` looks, so a
  successful `rm` would have resurrected the GENAI-DRIFT bug —
  no local wheel, silent fallback to the app lock's PyPI genai. It was inert
  ONLY by accident: `/opt/wheels` is a read-only bind mount
  (`Dockerfile.torch:80`) so the `rm` fails and `|| true` swallows it; making
  that mount rw would have broken all three arches at once. Narrowed to the
  GPU-flavoured variants the arm actually means (`*genai_cuda-*`,
  `*genai_rocm-*`, `*genai_directml-*`), verified against a fixture that the CPU
  wheel and plain `onnxruntime-*` survive while `*_gpu-*` and `*genai_cuda-*`
  are removed. GEN1 turned this from dormant to self-contradictory.
