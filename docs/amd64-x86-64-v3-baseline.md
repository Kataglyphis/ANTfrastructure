# amd64: built for x86-64-v3

The Linux amd64 images are compiled for `x86-64-v3` (AVX, AVX2, FMA, BMI1/2, LZCNT, MOVBE, F16C)
with `generic` tuning (owner decision 2026-11-12, CON264). Until then nothing in the Linux lane set
an instruction-set level for amd64, so every source build without run-time dispatch was SSE2 code.

**Not built yet.** The change is in the scripts; the first chain with it is the owner's call. The
published `:latest` is still generic x86-64, and the smoke reports such an image as `OLD`.

## What it costs

- **The CPU floor rises.** Intel before Haswell (2013), AMD before Excavator (2015), and the
  Celeron, Pentium and Atom parts without AVX2 cannot run the image.
- **Every package built in the image inherits the floor**: it links the image's libraries and is
  compiled by the same `cc`, so a consumer's DEB or AppImage needs an AVX2 CPU on the user's machine.
- **AVX-512 is never baseline.** Intel's consumer CPUs do not have it; `x86-64-v4` would exclude
  them. Tuning stays `generic`: `znver*` or `native` would bias the image to the build host.
- **Emulation.** amd64 code under `qemu-x86_64` needs a QEMU that emulates AVX2; the binfmt image
  `setup-rootless-binfmt.sh` installs is not pinned. Not tested: CI runs amd64 on x64 runners only.

## Where it is set

| Component | How | Where |
| --- | --- | --- |
| GCC, the image's `cc` | `--with-arch=x86-64-v3 --with-tune=generic` | `02-toolchain/build-gcc.sh` |
| OpenCV | `-DCPU_BASELINE=AVX2`, checked against the configure summary | `03-media/build/opencv/build-opencv.sh` |
| ONNX Runtime, FFmpeg, GStreamer, LiteRT, CPython, IREE | nothing: they inherit the compiler default | |
| Distro and PyPI binaries (codecs, OpenBLAS, numpy, torch) | unchanged; they dispatch at run time | |

The GCC arm keys on the effective target, because the amd64 host GCC is built without `--target`:
it covers that build and the `x86_64-linux-gnu` cross and Canadian native of an arm64 build
platform. `X86_64_GCC_ARCH` and `X86_64_GCC_TUNE` override it; an empty value drops the flag.
GCC takes `x86-64-v*` for `--with-arch` only, so the tuning is a separate flag. The reasons for a
compiler default over a `CFLAGS` export are the riscv64 ones:
[`riscv64-rva23-baseline.md`](riscv64-rva23-baseline.md#where-it-is-set).

## Not covered

- **clang** keeps LLVM's generic x86-64 default. Pass `-march=x86-64-v3`.
- **Rust** keeps its default, for image-built tools and for consumers. A consumer sets
  `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-cpu=x86-64-v3"`; the target-scoped
  name keeps the flag away from a `wasm32` build.
- **TVM** generates for the CPU its target string names: `llvm -mcpu=x86-64-v3`.
- **Windows x64** already builds ONNX Runtime, OpenCV and LiteRT at AVX2
  ([`windows-cross-builds.md`](windows-cross-builds.md)); its other source builds are a backlog item.

## The gates

- **Source:** `verify-critical-fixes.sh` pins the arm and both defaults;
  `tests/test-native-gcc-multiarch.sh` reads the configure line for the native, cross and Canadian
  builds and for the arches that must not get it.
- **Build:** the OpenCV configure fails when its `Baseline:` line lacks `AVX2`.
- **Image:** `check_amd64_isa` (`06-packaging/check-arch-isa.sh`, run by the runtime smoke) requires that `gcc -v` names
  `x86-64-v3`, that the default `cc` predefines `__AVX2__`, `__FMA__` and `__BMI2__`, that OpenCV's
  baseline has AVX2, and that the loader calls `x86-64-v3` supported. An image whose gcc predates
  the switch is `OLD`, not a failure. It does not grade each shipped binary: an x86 ELF carries no
  level tag.
- **Start-up:** the entrypoint asks the loader (`ld.so --help`) and refuses a CPU below the
  baseline with the cause instead of a later `Illegal instruction`. A loader it cannot read gives no
  verdict. A run that replaces the entrypoint, such as a GitHub `container:` job, skips the check.

## Cost of the switch

Editing `build-gcc.sh` re-keys the compiler image on every arch. The host GCC also compiles the
arm64 and riscv64 cross compilers, so their binaries change and all three arches' compile caches
are expected to miss once; read the first `sccache-stats|` lines of the chain to confirm. Cross it
with a fresh chain from the compiler stage, never a resumed one. The before and after measurement
is recorded in [`image-decisions.md`](image-decisions.md) when the chain has run.
