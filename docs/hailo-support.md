# Hailo support — image-chain integration plan

**Status: HAILO-10H IN THE STANDARD RUNTIME (2026-09-20). `:latest`
builds the Hailo payload by default on amd64 and arm64; riscv64 skips it (no
HailoRT support at any version). Hailo-8/8R/8L support was DROPPED the same
day — those devices need the `hailo8` branch (HailoRT 4.24.x), a different
source tree.** Host-side `.hef` compilation and the PCIe driver already have
procedures — [`linux-accelerator-images.md` § Edge
accelerators](linux-accelerator-images.md#edge-accelerators). This page owns the
design, the upstream facts it rests on, and what remains open.

**Proven 2026-09-20:** the payload was first proven as a standalone variant
(`:hailo-amd64` / `:hailo-arm64`, indexed as `:hailo`) and then folded into
`Dockerfile.torch`, so every `:latest` wrapper carries it. **The variant was
retired on 2026-09-22** (`Dockerfile.hailo` deleted, no `:latest-hailo`): it
built the same payload a second time, and the published `:hailo` was already a
generation behind `:latest`. Per
[`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags),
a variant exists only for a stack that cannot ship in the default image. The
build's own checks run before the
payload is accepted, so a broken element fails the build rather than shipping.
**pyhailort is built from source** (scikit-build-core, the `platform/`
directory) and installed into `/opt/venv`. Every image built before the
`HAILO_PYHAILORT_IPO` switch shipped it as an empty module that could never
import; the switch's default patches that and checks the module
([pyhailort](#pyhailort)). One honest caveat: upstream declares
`requires-python <3.14` and the image runs 3.14, so the wheel's metadata is
relaxed before the build and the install is followed by an import test — a
failure is REPORTED, never hidden. The wheel also stays staged at
`/opt/hailo/wheels/` for a ≤3.13 environment. The 2026-09-24 amd64 build imports
on 3.14; if an import fails there, that is upstream's declared boundary.
**TAPPAS IS built** (2026-09-20). Its README names GStreamer 1.16–1.20 as the
*tested* matrix, but the meson constraint is `>= 1.0` and it builds clean
against this image's 1.29.2 — the two load-bearing fixes are build-args, not
code patches: `libargs` is a Meson ARRAY (comma-separated elements, or only the
last survives) and the `open_source` include paths are explicit. Its
`hailofilter`/`hailocropper`/`hailooverlay`/`hailoaggregator`/`hailotracker` and
the rest load in the shipped image; libzmq is built in for the two zmq
elements. **The Dataflow
Compiler is staged, not fetched** — it is login-gated and x86_64-only; drop the
wheel into `linux/hailo-sdk/` and the amd64 wrapper installs it
(`linux/hailo-sdk/README.md`). The Model Zoo stays a host-side tool.

## What exists (2026-09-20)

| Piece | Where |
| --- | --- |
| Build script (HailoRT + `hailortcli` + `hailonet` + pyhailort wheel + TAPPAS + libzmq) | `linux/scripts/03-media/build/hailo/build-hailort.sh` |
| The build's two switches, the nested-build carrier and its gate, the pyhailort check ([two switches](#the-nested-build-cache-and-pyhailort-two-switches)) | `linux/scripts/03-media/build/hailo/hailo-build-lib.sh` |
| A seconds-long check that a nested build reaches the cache inside an image | `linux/scripts/03-media/build/hailo/probe-hailo-nested-cache.sh` |
| Tests | `linux/scripts/tests/test-hailo-build.sh` |
| Standard runtime build (amd64/arm64, riscv64 skips) | `linux/Dockerfile.torch` |
| Pins (`HAILORT_*`, `HAILO_PROTOBUF_*`, `TAPPAS_*`, `HAILO_LIBZMQ_*`) | `linux/scripts/01-core/versions.env` |
| Dataflow Compiler drop point (login-gated, gitignored) | `linux/hailo-sdk/` |
| Licence rows (MIT, LGPL-2.1-or-later, BSD-3-Clause) | `docs/deps/deps.json` |
| Build and run | [`linux-accelerator-images.md` § Hailo (in the standard image)](linux-accelerator-images.md#hailo-in-the-standard-image) |

## Phase 3: Windows HailoRT (LANDED 2026-09-21)

**The Windows lane builds HailoRT (library + `hailortcli`) on amd64 and arm64.**
TAPPAS stays Linux-only and pyhailort's Windows wheel is still open; what ships
today is the device runtime every Windows consumer needs.

| Piece | Where |
| --- | --- |
| Build script | `windows/scripts/build/Build-HailortFromSource.ps1` |
| Media branch (`media-core-built-hailo`, between opencv and the core merge) | `windows/Dockerfile.media-builder` |
| Driver stage + pins forwarding | `windows/Build-Buildkit.ps1` (`Get-Ver 'HAILORT_*'`) |
| Patches (three upstream Windows/clang-cl gaps) | `windows/scripts/patches/hailo/` |
| Smoke section 24 + the `HAILO_ROOT`/`HAILO_BIN` pointers | `windows/scripts/build/Test-Container.ps1` |
| Payload layout | `C:\runtime\hailo\{bin,lib,include}` (`libhailort.dll`, `hailopp.dll`, `hailortcli.exe`) |

Same shape as the Linux lane, with two Windows-specific facts:

- **Offline externals, pinned 1:1.** Upstream's `prepare_externals` clones ten
  repositories at configure time, unpinned. The script stages each at the SAME
  commits the Linux lane pins (plus protobuf 21.12 from its SHA-verified tarball)
  and configures with `HAILO_OFFLINE_COMPILATION=ON`.
- **Three upstream gaps, all patched** (probe-proven 2026-09-21,
  `out/build-logs/probe-hailo-amd64-*`):
  1. `quantization.hpp`'s `bankers_round` guard keys on `_MSC_VER`, which clang-cl
     defines on EVERY arch → the x86 intrinsics fail on ARM64 and on a bare x64
     clang-cl without `-msse4.1` (`__builtin_ia32_roundss needs target feature
     sse4.1`). The guard is now `MSVC && !clang && (x64||x86)`.
  2. `driver_os_specific.cpp` defines explicit-specialization members without
     `template<>`; clang-cl enforces the prefix MSVC tolerates.
  3. `os/windows/filesystem.cpp` is a stub that omits `LockedFile::~LockedFile()`
     while the header declares it → `hailortcli` fails to link
     (`undefined symbol: hailort::LockedFile::~LockedFile`). The destructor is
     added (the stub's `create()` returns `HAILO_NOT_IMPLEMENTED`, so there is
     nothing to release).

**Not yet on Windows**: TAPPAS, the pyhailort wheel, the GStreamer `hailonet`
element (`HAILO_BUILD_GSTREAMER` stays OFF — the binding exists upstream for
Windows but is a separate gate), the Dataflow Compiler (host-side tool anyway)
and any device execution (no Hailo device on the build host).

The Linux build runs in the **runtime image itself** (native GCC 16.2.0 + the
GStreamer dev files are already there), so the plugin links against exactly the
GStreamer the runtime ships. The first design built in `cross-android-<arch>`
instead; it works for amd64 but dies for arm64, because those images are
amd64-hosted cross toolchains and HailoRT's FetchContent externals invoke their
own nested cmake, which a cross `CMAKE_C_COMPILER` cannot reach
(`as: unrecognized option '-EL'`, then a Ninja/RPATH "not ELF-based" error from
a stale cross cache). Native is slower on arm64 (QEMU) and correct. That
explanation is not settled (review, 2026-09-24): the nested build runs under
`env -i` with the build host's own compiler, which is right for `protoc`, so the
`-EL` more likely came from the parent's compiler. A cross path has to diagnose it
first ([not built](#what-is-proven-and-what-is-not)).

**Build-args, not patches.** TAPPAS needed no GStreamer source changes: the
Meson `libargs` array (comma-separated) carries the HailoRT include paths and
`libxtensor`/`libcxxopts`/`librapidjson` point at `core/open_source/`, whose
header-only dependencies (xtensor, xtl, cxxopts, pybind11, rapidjson, Catch2)
are staged at pinned commits — upstream clones them from branches, including
`rapidjson: master`.


## The nested build cache and pyhailort: two switches

Two switches decide how the Hailo payload builds (2026-09-24). Each default is the
fast or the fixed path; the other value is the build as it was before.

| Switch | Default | The other value |
| --- | --- | --- |
| `HAILO_NESTED_CACHE` | `carry`: the protobuf build that HailoRT runs inside its own configure uses the compiler cache | `off`: that build runs uncached, as before |
| `HAILO_PYHAILORT_IPO` | `off`: upstream's forced LTO is patched out, so pyhailort is a real module | `upstream`: upstream's CMake as shipped, which under lld links an empty module, as before |

**How to pick.** Keep the defaults. For one run on the old path, export the switch
in front of `build-cross-chain.sh`, `build-runtime-manifest.sh` or
`build-runtime-artifacts.sh`, for example `HAILO_NESTED_CACHE=off bash
linux/scripts/build-cross-chain.sh ...`. Unset it to go back.

- `HAILO_NESTED_CACHE=off` when the nested-build gate below stops a build and the
  image is needed before the cause is known.
- `HAILO_PYHAILORT_IPO=upstream` when the pyhailort build, its module check or its
  install into `/opt/venv` fails.
- Any other value stops the chain before its first stage, and a runtime lane before
  its first build, with exit 2.
- Both are `Dockerfile.torch` ARGs. `lib-orchestrator.sh` forwards them only when
  set, so they need no `versions.env` line, and a switch re-keys only the wrapper's
  Hailo `RUN`, which re-runs on every lane anyway.
- A native host takes either value. The Jetson (`CROSS_BUILD_PLATFORM=linux/arm64`)
  builds Hailo inside the wrapper as the amd64 host does. The X100 is riscv64, which
  skips Hailo, so there the switches only pass the chain's check.

### Why the nested build was uncached

HailoRT's configure builds and installs a complete host protobuf 21.12, 200
objects, before it generates anything (`cmake/external/protobuf.cmake`). Every step
of that build runs as `env -i HOME=$ENV{HOME} PATH=/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin bash -l -c ...`
(`cmake/execute_cmake.cmake:7`). `setup_ccache` hands CMake the cache only through
the environment (`CMAKE_<LANG>_COMPILER_LAUNCHER`, `SCCACHE_SERVER_UDS`), which
`env -i` removes, and the script deletes `external/*-build` on every run. So those
200 objects compiled cold every time, while every compile the launcher did reach
was a hit. The 2026-09-22 lane's layer mtimes put arm64's configure at 384 s of its
595 s Hailo `RUN`, and amd64's at 22 s.

### The carrier

With `carry`, only the configure runs with another `HOME`: a new directory in the
`RUN`'s `/tmp` tmpfs, removed right after.

- It mirrors the real `HOME` with symlinks, so the configure reads the same files as
  before (git config, the CMake package registry).
- The nested `bash -l` reads its `.bash_profile`. That runs the real login file
  first, then puts `.hailo-cache-bin` first on `PATH` and exports both CMake
  launchers and every exported `SCCACHE_*` and `CCACHE_*` variable, except the
  `*_VERSION` and `*_SHA256` pins from `versions.env`.
- `.hailo-cache-bin` holds only the parent's `sccache` and `ccache`. The clean `PATH`
  finds the distro sccache 0.13 in `/bin` before the pinned 0.17 in `/usr/local/bin`.
  Compiles between the two worked when tried, but the 0.13 client's stats requests
  fail against the 0.17 server, and with no server running it starts a 0.13 one on
  the same socket ([symptom](failure-modes.md#hailorts-configure-is-slow-while-the-cache-looks-healthy)).
  Client and server are one binary now.

Nothing else crosses: no compiler, no flag, no other `PATH` entry. One difference
shows in the image: `off` still writes Eigen's package-registry entry to
`/root/.cmake/packages`, where it points into the cache mount and dangles, while
with `carry` it stays in `/tmp`.

### The gate

After the configure, `hailo_assert_nested_cache_reached` compares the objects in
`external/protobuf-build/.ninja_log` with the compile requests the cache counted
while the configure ran.

| What it reads | `carry` with a launcher | `off`, or no launcher |
| --- | --- | --- |
| fewer requests than half the objects | **fails the build** | warns |
| fewer requests than objects | warns | warns |
| no `.ninja_log`, or no objects in it | **fails** (the nested build moved) | warns |
| counters it cannot read | warns | warns |

In `carry` mode the configure also fails before it starts when
`execute_cmake.cmake` no longer holds that exact `env -i` line: a HailoRT bump must
re-derive the carrier. `USE_SCCACHE=0` only switches the launcher to ccache, so the
gate stays armed. `USE_CCACHE=0` leaves no launcher at all: nothing is carried, and
the gate warns.

Each phase prints one line to stderr, `[CACHE] hailo/<phase>: secs=N requests=+R
hits=+H misses=+M launcher=... cap=...`, for `hailort-configure`, `hailort-build`,
`pyhailort`, `libzmq` and `tappas`. The saving is `hailort-configure`'s `secs` set
against an `off` run's.

`probe-hailo-nested-cache.sh`, beside the build script, tells in seconds and without
network whether a nested build reaches the cache inside a given image. It builds a
24-file project through the same `env -i` line three times, `off`, then `carry` cold
and warm, and exits 0 when the warm pass hit on every object. Run it in a fresh
container ([why](failure-modes.md#hailorts-configure-is-slow-while-the-cache-looks-healthy)).

### Cache caps in the Hailo RUN

The Hailo `RUN` sets `SCCACHE_CACHE_SIZE=30G` and `CCACHE_MAXSIZE=30G`, the values
in `Dockerfile.base`, and `tests/test-hailo-build.sh` pins the pair to it. Why the
`RUN` needs them:
[`build-cache-tiers.md` § The shipped image's cache dirs](build-cache-tiers.md#the-shipped-images-cache-dirs).

### pyhailort

Upstream's `bindings/python/src/CMakeLists.txt` sets
`CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE` as a normal variable, so no `-D` can
change it. GCC then writes slim LTO objects, `setup_lld_linker` links with lld, and
lld cannot read GCC's LTO code. Every image built before this switch shipped a
4 KB `_pyhailort` without `PyInit__pyhailort`, on amd64 and arm64.

`HAILO_PYHAILORT_IPO=off` turns that line to `FALSE` in the cached source, and
`upstream` turns it back. The twelve binding sources then really compile, at
`compute_cpp_heavy_jobs`, and cache. `hailo_check_pyext` checks both the wheel's
module and the one installed into `/opt/venv`: the target's ELF machine and a
defined `PyInit__pyhailort`. Under `off` a failed check stops the build, and so
do a wheel that does not install and a missing wheel, because the installed
module is what ships. Under `upstream` all three warn, which is how the image
shipped before. A run without `/opt/venv`, outside the image, only stages the
wheel.

`import hailo_platform` is tried last, and it only warns, in both modes: upstream
declares `requires-python <3.14`, and the import on the image's 3.14 is proven on
amd64 only. The gate is the `PyInit__pyhailort` export, not the import.

**The build backend is not pinned.** `build_pyhailort` installs
`scikit-build-core>=0.10` and `pybind11>=2.13.6,<3` from PyPI, unpinned and
unhashed. Under `off` that reaches the image: pybind11's headers compile into the
module that ships, so a new pybind11 2.x release changes those bytes and
recompiles the twelve sources cold, under QEMU on arm64. Before, the module was an
empty stub and pybind11 never reached `/opt/venv`. Pinning pybind11 needs a new
2.x key in `versions.env` (`PY_PYBIND11_VERSION` is 3.x), which re-keys every
stage from base, so both pins wait for the next planned `versions.env` re-key
([open question](#open-questions)).

### What is proven, and what is not

Proven on 2026-09-24 on amd64, natively (32 vCPU): the worktree's `01-core` and
`03-media` at the paths `Dockerfile.torch` copies them to, in the local
`:latest-cross` image (built 2026-09-12), as root, with a fresh `/opt/hailo` per run.

| Run | HailoRT configure | Whole script | The nested build |
| --- | --- | --- | --- |
| `carry`, cold cache | 35 s | 325 s | 243 requests, 200 misses |
| `carry`, warm | 9 s | 36 s | 243 requests, 238 hits |
| `off`, warm | 32 s | 68 s | 38 requests, all the parent's own |

pyhailort built as a 1.7 MB module that exports `PyInit__pyhailort`, and
`import hailo_platform` works on Python 3.14; `upstream` rebuilt the 4 KB stub and
only warned. `USE_SCCACHE=0` carried ccache instead and passed the gate. The probe
reported CACHED as root and as uid 1001. Unit tests: `tests/test-hailo-build.sh`.
The install checks the review added (a failed install and a missing wheel) ran later,
as `install_pyhailort` alone in the same image against its uv 0.12.13 and `/opt/venv`
(Python 3.14.4): a stub wheel, a truncated one and none, under both values. No full
build has run with them.

Not proven: arm64 under QEMU, where the saving is (estimated at 2.5 to 4 minutes
per arm64 lane), the BuildKit `RUN` itself, the Jetson and the X100. On the build
host, from the repo root, the probe first (seconds natively, longer under QEMU):

```bash
for p in amd64 arm64; do
  nerdctl run --rm --platform "linux/$p" -v "$PWD/linux/scripts:/opt/hub:ro" --entrypoint bash \
    ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest /opt/hub/03-media/build/hailo/probe-hailo-nested-cache.sh
done
```

Then two runtime lanes with the defaults, which publish nothing. The first fills
the cache, and the second's `hailort-configure` line should show hits for nearly all
its requests, next to `exports PyInit__pyhailort` twice per arch:

```bash
for i in 1 2; do
  CROSS_LOCAL_CONTEXT_HANDOFF=0 RUNTIME_NO_CACHE=1 bash linux/scripts/build-cross-chain.sh --only runtime --no-push \
    --target-arches amd64,arm64 2>&1 | tee "out/build-logs/hailo-carry-$i.log"
done
grep -hE '\[CACHE\] hailo/|\[hailo\]' out/build-logs/hailo-carry-*.log
```

`RUNTIME_NO_CACHE=1` makes BuildKit run the Hailo `RUN` again rather than take it
from its cache; it re-runs the package build too, so each pass costs a runtime lane.
For the old numbers, add `HAILO_NESTED_CACHE=off HAILO_PYHAILORT_IPO=upstream` to a
third pass.

**Not built: a cross fast path.** Building the payload in the amd64 android stage
and only installing it in the wrapper would remove most of the emulated time left on
arm64. It was designed (speedup hailo-arm64) and not built: the `-EL` failure above
is not diagnosed, and the wrapper's final stage would need a restructure that no
BuildKit here could test.

## Why an image chain

The runtime artifacts are deployed to boards with a Hailo-10H accelerator.
Until 2026-09-20 the software was installed on the host by hand: HailoRT and
the GStreamer element were absent from every image, so a consumer either
apt-installed them outside the container or skipped the device. The standard
runtime now ships them pinned, verified and gated, the same way CUDA/ROCm and
the QNN EP are handled.

## Upstream facts (2026-09-19)

### Device families split the source tree

| Family | Branch | Latest release | Notes |
| --- | --- | --- | --- |
| Hailo-8, Hailo-8R, Hailo-8L | `hailo8` | v4.24.0 | **DROPPED 2026-09-20.** These devices need this branch (HailoRT 4.24.x), a different source tree and pin set; restore it only by re-adding a second pin set |
| Hailo-10 | `master` | **v5.4.0** (`f5195903`) | **the supported family**; 10H is PCIe |
| Hailo-15 | `master` | v5.4.0 | an SoC with its own apps repo — **out of scope** |

A single pin cannot serve both lines: the branch is part of the pin
(`HAILORT_BRANCH` + `HAILORT_COMMIT`), and the version keys differ.

### Components, licenses, where each one runs

| Component | Source | License | Where |
| --- | --- | --- | --- |
| `libhailort`, `hailortcli`, `pyhailort` | [`hailo-ai/hailort`](https://github.com/hailo-ai/hailort) | MIT | in the image |
| `hailonet` GStreamer element | same repo, `hailort/libhailort/bindings/gstreamer` | LGPL-2.1-or-later | in the image (media) |
| Hailo PCIe driver | [`hailo-ai/hailort-drivers`](https://github.com/hailo-ai/hailort-drivers) | GPL-2.0 | **host only** — out-of-tree DKMS, never in an image |
| TAPPAS | [`hailo-ai/tappas`](https://github.com/hailo-ai/tappas) | LGPL-2.1-or-later | **in the image** (with libzmq, MPL-2.0, for the zmq elements) |
| Hailo Model Zoo | [`hailo-ai/hailo_model_zoo`](https://github.com/hailo-ai/hailo_model_zoo) | MIT | host-side, with the login-gated Dataflow Compiler |

Both copyleft rows need a source pointer in
[`third-party-licenses.md`](third-party-licenses.md) when the dependency lands;
`spdx` is mandatory in `deps.json`.

### HailoRT build knobs (CMake)

`HAILO_BUILD_GSTREAMER` (the `hailonet` plugin), `HAILO_BUILD_TOOLS`,
`HAILO_BUILD_EXAMPLES`, `HAILO_BUILD_USB`, `HAILO_BUILD_HAILORT_SERVER`,
`HAILO_BUILD_GENAI_SERVER`, `HAILO_BUILD_OLLAMA`, and
`HAILO_OFFLINE_COMPILATION`. The default build fetches protobuf and gRPC with
FetchContent, so the supply-chain rule applies: either vendor them or pin the
fetch with verification — an unverified network fetch inside a `RUN` is the
class this repo refuses everywhere else.

### TAPPAS pairing

TAPPAS v5.4.0 pairs with HailoRT **v5.4.0 for Hailo-10H** (the Hailo-8 line
went with that family's drop). It is LGPL-2.1-or-later and targets Ubuntu x86
24.04/22.04, Ubuntu aarch64 20.04 (manual install), Raspberry Pi OS and Yocto —
no Windows, no riscv64. Its README's **1.16 | 1.18 | 1.20** is the *tested*
matrix; the meson constraint is `>= 1.0`, and 1.29.2 builds clean (proven).

## Compatibility findings (resolved 2026-09-20)

1. **GStreamer: no gap in practice.** The image's 1.29.2 builds TAPPAS clean —
   the only fixes are build-args (`libargs` comma-array, explicit `open_source`
   paths). No GStreamer source patches, no second GStreamer tree.
2. **Architecture.** amd64 + arm64; riscv64 unsupported (HailoRT and TAPPAS
   both). The script refuses it.
3. **Windows.** HailoRT supports Windows; TAPPAS does not — a separate phase.
4. **Android.** PCIe/M.2 — not applicable.
5. **The Dataflow Compiler stays off-image** unless staged (login-gated,
   x86_64-only; `linux/hailo-sdk/`).

## Integration design (Linux lane)

The standard runtime builds the payload itself; there is no Hailo variant tag
(retired 2026-09-22).

### Layers (as implemented)

- **`linux/Dockerfile.torch`** (the standard wrapper, per arch) — before the
  runtime user is created, it runs `build-hailort.sh` with
  `HAILO_BUILD_GSTREAMER=ON` and `HAILO_OFFLINE_COMPILATION=ON` (externals
  staged from verified sources), installs the plugin into
  `${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0`, writes
  `/etc/ld.so.conf.d/000-hailo.conf`, symlinks `hailortcli`, and self-checks
  both. riscv64 prints a skip line and builds nothing. The image has GCC 16.2.0,
  cmake, ninja and the GStreamer dev files, so the build is native.
- **`Dockerfile.media` / `Dockerfile.package` / `Dockerfile.android`** —
  untouched; the build lives where the compiler and GStreamer dev files already
  are, so the media stage's fan-out is not re-keyed.
- **riscv64 skips by construction** — HailoRT has no riscv64 support, the script
  refuses it, and the Dockerfile branches around it. That is the documented
  exemption, not a gap.

### Pins (`versions.env`, single source)

`HAILORT_VERSION`, `HAILORT_COMMIT` (for v5.4.0 the value is both the tag and
the commit — a lightweight tag), `HAILORT_SOURCE_SHA256`, and the externals:
`HAILO_PROTOBUF_VERSION`/`_SHA256`, plus `TAPPAS_VERSION`/`_SHA256` and
`HAILO_LIBZMQ_VERSION`/`_SHA256` (TAPPAS's zmq elements). master has no
`grpc.cmake` (the hailo8 branch did), so there are no gRPC keys; TAPPAS's own
header-only externals are commit-pinned in the build script. The same values are the ARG defaults in
`Dockerfile.torch`, and `sync_versions.py --check` keeps
them in step.

### Gates

| Gate | State |
| --- | --- |
| Build-stage self-check (`hailortcli --version`, `gst-inspect-1.0 hailonet`) | in `build-hailort.sh`, fails the build |
| Runtime-stage self-check (`hailortcli`, `gst-inspect-1.0 hailonet` after the install) | in the `Dockerfile.torch` Hailo `RUN` |
| The nested protobuf build reached the compiler cache | `hailo_assert_nested_cache_reached`, fails a `carry` build ([the gate](#the-gate)) |
| pyhailort exports `PyInit__pyhailort` for the target, wheel and `/opt/venv` | `hailo_check_pyext` and `install_pyhailort`: under `HAILO_PYHAILORT_IPO=off` a failed check, a failed install or a missing wheel fails the build; `import hailo_platform` only warns ([pyhailort](#pyhailort)) |
| `docs/deps/deps.json` + `third-party-licenses.md` | MIT, LGPL-2.1-or-later (with source pointer), BSD-3-Clause, Apache-2.0 rows added |
| `verify-media-artifacts.sh` / `smoke-runtime-image.sh` | **not wired yet** — the standard chain now carries Hailo, so the runtime smoke is the natural next gate |
| Bundle closure | not applicable — the payload ships in the full image, not a bundle |

### Host and run contract

- Host: PCIe driver (GPL-2.0, DKMS) and `modprobe hailo_pci` — already in the
  Edge accelerators section; link, do not restate.
- Run: `--device=/dev/hailo0` (plus the `video` group where the board needs it).
- Consumer contract: the `hailonet` element on the image's `GST_PLUGIN_PATH`,
  `hailortcli` on `PATH`, and the `.hef` path supplied by the app.

## Phased rollout

1. **Phase 0 — decisions.** Family: **Hailo-8L/8** (`hailo8`, HailoRT 4.24.x),
   the M.2 cards; Hailo-10H (`master`, 5.4.x) needs a second pin set. TAPPAS:
   **no** — `hailonet` only (option (a) below).
2. **Phase 1 — HailoRT userspace + `hailonet`: amd64 DONE.** Built, verified
   and published as `:hailo-amd64`; arm64 is the next build (QEMU, needs a disk
   window).
3. **Phase 2 — TAPPAS (optional, timeboxed).** Only if a consumer needs its
   pipelines; evaluate option (b) and stop if the patches grow.
4. **Phase 3 — Windows HailoRT (optional).** Separate lane, separate gates.
5. **Phase 4 — consumer adoption.** Consumer repos document the device
   passthrough and model path, and the cat-detection stream can move from ONNX
   CPU to `.hef` on the device.

## Open questions

- Does `hailonet` configure and load against the image's GStreamer? **Answered
  2026-09-20: yes** — built and loaded on amd64 (see the status block).
- Does the protobuf/gRPC offline staging configure cleanly, and how long does
  the gRPC submodule clone take? **Answered: yes**; all 16 commit-pinned
  externals are staged by `stage_remaining_externals` (protobuf as a verified
  tarball, gRPC as a tag clone with submodules).
- Which device does the consumer actually run? That answer may add the
  Hailo-10H pin set.
- `pyhailort`, if ever needed: it ships in Hailo's `.deb`, not the source build.
- Pin pyhailort's build backend, `scikit-build-core` and `pybind11` 2.x, at the
  next planned `versions.env` re-key, with a real build
  ([why it floats](#pyhailort)).
