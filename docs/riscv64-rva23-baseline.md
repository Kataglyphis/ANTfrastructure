# riscv64: build at Ubuntu's own baseline (RVA23, with vector)

Every riscv64 artefact this chain builds targets `rva23u64_zifencei` /
`lp64d` — the same ISA Ubuntu 26.04 (resolute) builds its own riscv64 port at.
Before 2026-09-01 they were built at the cross toolchain's default `rv64gc`,
which is **below** the platform the image already stands on.

## Why this costs no compatibility

The intuition "turning on vector breaks non-vector hardware" is backwards here.
Measured in the shipped riscv64 image on 2026-09-01:

| object | `Tag_RISCV_arch` | vector? |
| --- | --- | --- |
| Ubuntu's `/lib/riscv64-linux-gnu/libc.so.6` | `rv64i2p1_…_b1p0_v1p0_…_zvl128b1p0` | yes — 997 `vsetvli` |
| our `/opt/opencv5/lib/libopencv_core.so` | `rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0_zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0_zcd1p0` | no |

The image's own glibc and dynamic loader require RVV 1.0, so a board without a
vector unit **cannot run this image today**, regardless of what we compile. The
hardware floor is set by Ubuntu, not by us. Our binaries were simply the only
sub-baseline objects in the image, giving up Zba/Zbb/Zicond and every vector
kernel for nothing.

## Why `rva23u64_zifencei` and not `rv64gcv`

`rv64gcv` is a strictly narrower subset: it adds V but still leaves out the
bit-manipulation and conditional-move extensions the distro assumes. Of the two
profile spellings, only `rva23u64_zifencei` reproduces Ubuntu's attribute string
exactly — plain `rva23u64` omits `zifencei2p0`, which apt's libc carries. Verified
by compiling with each and diffing `readelf -A` against apt's `libc.so.6`.

`-mabi` stays `lp64d`, unchanged. `e_flags` are identical, so rv64gc and
rva23u64 objects link and run together — which is what makes it safe to switch
our own builds while every apt library stays as it is.

## Where it is set

The single load-bearing edit is the **cross GCC's built-in default**
(`02-toolchain/build-gcc.sh`, the `riscv64-*` case: `--with-arch` / `--with-abi`,
overridable with `RISCV_GCC_ARCH` / `RISCV_GCC_ABI`). A compiler default cannot
be erased by a `-DCMAKE_C_FLAGS=` whole-string reset, cannot leak into an amd64
host sub-build, and is inherited by meson cross builds — all of which a global
`CFLAGS` export would get wrong.

Four consumers need more than `-march`, because they gate their vector paths on
their own switches:

| consumer | what it needs | where |
| --- | --- | --- |
| OpenCV | `CPU_BASELINE=RVV`, `WITH_HAL_RVV=ON` | `03-media/build/opencv/build-opencv.sh` |
| ONNX Runtime | `onnxruntime_USE_RVV=ON` | `03-media/build/onnxruntime/build/lib/common.sh` |
| Rust | `RUSTFLAGS -C target-feature=+v,+zvl128b` (no `gcv` triple exists) | `01-core/cross-env.sh` |
| gst-plugins-rs | its `cargo_wrapper.py` **overwrote** `RUSTFLAGS`; patched to merge | `patches/gstreamer/003-cargo-wrapper-cross-rust-target.patch` |

Android riscv64 keeps RVV **off** (`03-media/build/opencv/android/build-android.sh`):
that disable works around an NDK-clang bug with sizeless RVV types, not a
platform choice.

TVM and IREE still need a codegen-target change rather than a compile flag —
their shipped compilers emit code at runtime. That is open; see
docs/refactoring-backlog.md.

## The gate

`06-packaging/smoke-runtime-image.sh` reads `Tag_RISCV_arch` off the shipped
`libopencv_core.so`, `libavcodec.so`, `libgstreamer-1.0.so` and `libc.so.6` and
fails any that lacks `_v1p0`. It asserts the **bytes**, not the build log, and an
empty probe reports `NONE` rather than passing vacuously.

## Cost

The change invalidates the warm riscv64 compiler cache: the next riscv64 build
is cold. LLVM alone is roughly 50 minutes warm against many hours cold.
