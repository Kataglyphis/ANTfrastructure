# ROCm on the Windows lane (`-Variant rocm`)

`.\windows\Build-Buildkit.ps1 -Variant rocm` (amd64 only) builds the AMD image
`:winamd64-rocm`. Since 2026-09-23 the ROCm layer sits in the **sdk slot**, like
`Dockerfile.nvidia` on the GPU lane, so toolchain and media build on top of it and can
turn on ROCm and AMD-GPU features. Every one of them is gated on
`(Get-GpuEnvironment).HasRocm`: the cpu and nvidia lanes keep their flags and outputs.

**Nothing on this page has been seen executing on a GPU.** Windows containers get
DirectX only, and on this host GPU passthrough is additionally blocked by the
26100/26200 build skew ([windows-build-resources.md](windows-build-resources.md)). Every
image check below is GPU-less: presence, linkage, listings, compile-only. GPU proof
belongs on the bare host.

## What the rocm lane enables

| Component | Enabled on the rocm lane | Mechanism | Needs the ROCm layer |
| --- | --- | --- | --- |
| GStreamer 1.29.2 | `hip`, `amfcodec`, `d3d11`, `d3d12` pinned `enabled` (already built by `auto` on every lane) | HIP (dlopen), AMF, D3D | hip: at run time |
| FFmpeg n9.0.2 | AMF encoders, decoders, filters, `amf` hwdevice | AMF (driver) | no |
| OpenCV 5.0.0 | OpenCL T-API (already on every lane); clBLAS/clFFT probes pinned off | OpenCL | the ICD loader it ships |
| IREE | HIP HAL driver, `rocm` compiler target (gfx1201) | ROCm/HIP | at run time |
| TVM | OpenCL runtime; ROCm codegen + runtime as a **spike** (`TVM_ROCM=1`) | OpenCL, ROCm/HIP | spike: yes |
| LiteRT-LM | GPU backend (WebGPU over Dawn on D3D12) | D3D12 | no |
| PyTorch | torch 2.13.0+rocm10.0.0, torchvision 0.28.0+rocm10.0.0 | ROCm/HIP (own runtime in the wheels) | no |
| llama.cpp | official Windows ROCm build b11115 (`ggml-hip`) | ROCm/HIP | hipBLAS/rocBLAS |
| MIGraphX + ORT plugin EP | MIGraphX 2.17.0 from source, `migraphx-ep.dll` as a **spike** | ROCm/HIP | yes |
| ONNX Runtime | unchanged: CPU + DirectML (ORT >= 1.23 has no ROCm EP) | DirectML | no |

`-NoRocmSpikes` drops the two spikes (the migraphx stage and `TVM_ROCM`).

**Not possible on Windows**, checked against upstream: the ORT ROCm EP (removed in
1.23), rocDecode / rocJPEG / rocAL (Linux only), any HIP path in FFmpeg, OpenCV or LiteRT,
OpenCV's MIGraphX dnn backend (`NOT UNIX`-guarded), IREE's `amdgpu` HAL driver (needs
HSA/ROCR), TVM with RCCL.

## The ROCm layer (`Dockerfile.rocm`)

**Built by `Build-Buildkit.ps1 -Variant rocm`** (amd64 only). Since 2026-09-23 the ROCm
layer sits in the **sdk slot**, where `Dockerfile.nvidia` sits on the GPU lane (owner
directive 2026-09-23):

```
base -> sdk = rocm -> toolchain -> media (all branches + merge) -> migraphx -> llama -> torch -> final -> smoke
```

Toolchain and media now build on top of `GPU_TYPE=rocm`. That lets media turn on ROCm/AMD-GPU
features behind `HasRocm` (below). The features stay optional: the cpu and nvidia lanes send the
same configure/build flags as before.

**Tags.** `bk-windows-base` is shared. Every tag from sdk on carries a `-rocm` infix
(`Get-BkTag`):
- `bk-windows-sdk-rocm`
- `bk-windows-toolchain-rocm`
- `bk-windows-media-core-{onnx,ffmpeg,opencv,hailo}-rocm`, `bk-windows-media-core-rocm`
- `bk-windows-media-{litert,tvm}-rocm`, `bk-windows-media-rocm`
- `bk-windows-media-migraphx-rocm`, `bk-windows-media-llama-rocm`
- `bk-windows-torch-rocm`
- `bk-winamd64-rocm`

A rocm run therefore never overwrites a default image. The cpu and nvidia tags have not moved;
nvidia still shares the default names. A golden table in `Driver.Variant.Tests.ps1` locks both
lanes on amd64 and arm64.

The old `bk-windows-rocm` tag is orphaned: remove it by hand (admin `nerdctl --namespace
buildkit rmi`). Rocm runs from before this change wrote CPU-identical toolchain and media under
the default tags; that is harmless and needs nothing.

**Stages and switches.**
- `-Stages` takes `base,sdk,toolchain,media,migraphx,llama,torch,final`.
  - `migraphx` and `llama` are rocm-only. Other variants drop them from the default list and
    refuse them when named.
  - `-Stages rocm` is gone. It is refused with a pointer to the sdk slot.
- `migraphx` builds `Dockerfile.rocm-migraphx` (target `built`) FROM `bk-windows-media-rocm`.
  Its pins come from `Get-MediaBranchVersionArg -Branch rocm-migraphx`.
- `llama` builds `Dockerfile.rocm-llama` (target `built`) FROM the migraphx image.
- `torch` builds FROM the llama image.
- `-NoRocmSpikes` drops `migraphx`, so llama builds FROM the merged media. It also passes
  `TVM_ROCM=0` instead of `1` to media-tvm.
- Two build-args are sent on the rocm lane only (`Get-BkRocmStageArg`):
  - `TVM_ROCM` to media-tvm;
  - `TORCH_ROCM=1` plus every `TORCH_ROCM_WINDOWS_*` pin to `Dockerfile.torch`.

  Both consumers declare them with default `0`, so the cpu and nvidia solves receive nothing new.
- `-ConcurrentAux` children get `-Variant rocm` (and `-NoRocmSpikes`). Without it they would
  build litert/tvm FROM the default toolchain, under default tags.
- `-Variant rocm -Stages torch,final` reuses `bk-windows-media-llama-rocm`.

**Refused at launch:**
- arm64;
- `-Gpu` together with rocm;
- a push tag other than `:winamd64-rocm` (and a non-rocm run pushing to it);
- `-NoRocmSpikes` off the rocm lane;
- `-Stages migraphx` together with `-NoRocmSpikes`;
- a rocm `-Stages` list that skips a post-media stage between two it builds. Example:
  `media,torch` is refused, because torch would build FROM an earlier run's llama image
  (backlog #39).

The merge-skip guard also refuses migraphx, llama, torch and final.

**Refused in the stage:** `Install-Rocm.ps1` stops when its base already carries CUDA or ROCm
(`GPU_TYPE`, `CUDA_ROOT`, `CUDA_PATH`). The rocm sdk builds FROM the plain base, never FROM an
nvidia sdk and never on top of a second ROCm layer.

**The `HasRocm` contract.** `Get-GpuEnvironment` returns `HasRocm` (true only when
`GPU_TYPE=rocm`) and `RocmRoot`. It throws when `GPU_TYPE=rocm` but `HIP_PATH`/`ROCM_PATH` has no
`lib\cmake\hip`, because a mis-plumbed layer would otherwise build CPU flags silently.

Every rocm feature is gated on `HasRocm`, which the cpu and nvidia lanes can never enter. That
includes features that need the AMD driver but not ROCm (AMF, OpenCL, D3D12, WebGPU), by owner
decision.

ORT stays CPU + DirectML on this lane and logs `ROCm layer present: CPU+DML ORT`. ORT >= 1.23 has
no ROCm EP, and the dead `onnxruntime_USE_ROCM` branch was deleted.

**CMake isolation.** With `C:\TheRock\build\bin` on PATH, CMake treats `C:\TheRock\build` as a
package prefix: a PATH entry ending in `bin` makes its parent a search prefix. TheRock ships
`lib/cmake/{flatbuffers,llvm,clang,lld,hip,...}` and `share/cmake/nlohmann_json` there. ORT
v1.30.0 asks for flatbuffers (`FIND_PACKAGE_ARGS 23.5.9`) and nlohmann_json (`3.10`) through
`find_package` first.

- `Invoke-CmakeConfigure` therefore appends `-DCMAKE_IGNORE_PREFIX_PATH=<ROCm tree>` on the rocm
  lane (`Get-CMakeRocmIsolationArgs`). Elsewhere it appends nothing, so cpu/nvidia command lines
  are unchanged.
- A build that needs TheRock's packages (`find_package(hip)`, hipblas, ...) passes
  `-AllowRocmPrefix`.
- Builds that bypass `Invoke-CmakeConfigure` must isolate themselves or show why they cannot leak.
  The toolchain's patched LLVM (raw cmake) cannot leak:
  - its runtimes find LLVM/Clang with `NO_DEFAULT_PATH` (llvmorg-23.1.1
    `runtimes/CMakeLists.txt:89-90`);
  - TheRock's zlib/zstd sit only in `lib\rocm_sysdeps`;
  - there is no libxml2 and no python.exe in the tree.
- A header-only leak (nlohmann_json) leaves no trace in a binary. On the first rocm run, grep the
  onnx stage log for `TheRock`: only the ignore-prefix line should match.

**HIP device code** compiles only with TheRock's AMD clang
(`C:\TheRock\build\lib\llvm\bin\clang++.exe`), passed by absolute path and never through PATH.
The hub's patched clang-cl is built with `LLVM_TARGETS_TO_BUILD=AArch64;X86` and has no AMDGPU
backend. Host-only HIP consumers stay on clang-cl.

**Smoke gate.** It runs the CPU suite and floor (160), then `Test-RocmImage.ps1` (`EXPECT_ROCM=1`):
1. the env contract;
2. no CUDA;
3. AMD's LLVM not shadowing `clang-cl`/`clang`/`lld-link`;
4. `.info\version` matching the pin;
5. device bitcode present;
6. a `hipcc` compile for gfx1201;
7. then every `windows/scripts/build/rocm-checks/*.ps1`, sorted by name.

The rules for the checks:
- Each check writes zero or more finding strings (empty = pass) and needs no GPU.
- A throw is a finding that names its file.
- A missing or empty folder is a finding.
- Any finding fails the gate.
- Checks run under `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- Their exit codes are ignored.
- The gate bind-mounts `windows/scripts`, so a check edit needs no image rebuild.

**Source.** AMD's Windows tar install (rocm.docs.amd.com, install → Windows → tar):
`https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-<family>-<release>.tar.gz`.
That is the same TheRock release, from the same host, that
`linux/scripts/01-core/setup-rocm-repo.sh` installs on Linux as apt packages.

`windows/scripts/host/Install-Rocm.ps1` downloads it, verifies it, and extracts it with System32
`tar.exe` into `C:\TheRock\build` (AMD's documented path). It then checks the layout and runs
`hipcc --version` inside the container. That step now runs on the plain base, with no VS
environment loaded.

**No checksum from AMD.** Measured 2026-09-22: there is no `.sha256`, `.sig` or `.asc` sidecar,
no `SHA256SUMS`, and no hash fragment on the pip index. `ROCM_WINDOWS_TARBALL_SHA256` is
therefore self-measured and pinned, and the script refuses an empty or malformed pin.

| Family | Covers | Bytes | SHA256 |
| --- | --- | --- | --- |
| `gfx120X-all` (pinned) | RDNA4, incl. RX 9070 XT (gfx1201) | 2,282,922,923 | `75da73c483cbc0456d9008f2079b333f4f9d3b7744705378ff8007e502ca38c5` |
| `multiarch` | every supported GPU | 4,796,456,804 | `ebe454fe9ad663655177462187a4c86c72fd0537638f6cbea34660ddebf40056` |

**Disk.** The `gfx120X-all` tree unpacks to **9.56 GB** in 10,544 files. At its peak the sdk
stage holds the 2.28 GB tarball, the tree and its layer export at once, so `Get-StageDiskFloorGb`
gives `Dockerfile.rocm` a 45 GB floor (the default is 40). That figure is calculated, not
measured.

The tree is stored once, as a parent layer, under every later rocm stage, so the toolchain and
media floors are unchanged. What grows is the store itself: a second full toolchain + media set
beside the default one.

**Why the sdk slot, and what it costs (2026-09-23).** Until 2026-09-22 the layer forked after
media, because nothing in media consumed ROCm. The owner moved it into the sdk slot, like nvidia,
so media can build ROCm/AMD-GPU features behind `HasRocm`.

The cost is that the rocm lane shares only `base` with the default image. Its first run rebuilds
patched LLVM, all of media, the merge and torch. Cold figures from CPU amd64 run 20260919-021220:
- patched-llvm 3749 s;
- onnx / ffmpeg / opencv / core 1023 / 730 / 859 / 601 s;
- litert 3535 s, tvm 2832 s;
- merge 4314 s, torch 773 s;
- about 5.3 h in total.

sccache hashes no `PATH`/`HIP_PATH`/`ROCM_PATH` for C/C++, so unchanged compile commands may hit
the shared cache; that is unmeasured. A ROCm pin bump, or an edit to `Install-Rocm.ps1` or
`Dockerfile.rocm`, now rebuilds the whole rocm toolchain and media.

The alternative placement, toolchain -> rocm -> media, would keep patched LLVM shared. It was
not chosen.

**PATH.** `Dockerfile.rocm` sets the variables AMD documents (`HIP_PATH`, `ROCM_PATH`,
`HIP_PLATFORM`, `HIP_DEVICE_LIB_PATH`, `LLVM_PATH`) with one deliberate exception: AMD's page
also adds `lib\llvm\bin` to PATH. That directory holds AMD's own `clang-cl.exe`, `clang.exe` and
linker, and every compile here must use the patched clang-cl. So only `bin\` is added, and it
goes **last**, because it also carries its own `flatc.exe`, `OpenCL.dll` and `amdocl64.dll`.

Both rules now protect every toolchain and media compile, not just torch.
`Rocm.Install.Tests.ps1` fails if either rule is broken.

**Licences.** See [Redistribution](#redistribution) below.

**Not proven by anything here:** that HIP code runs. Windows containers get DirectX/DirectML
only, so a GPU check needs the bare host (Windows 11 25H2, with the RX 9070 XT re-enabled
outside any build window):
- `hipInfo`;
- the family's `-tests` tarball;
- a torch matmul compared against the CPU. This one is required, because upstream TheRock#8379
  reports torch+ROCm returning zeros on exactly that card.

## GStreamer on the rocm lane

GStreamer 1.29.2 builds its AMD paths on **every** lane already. Meson `auto` needs only in-tree stubs, the vendored AMF headers and the Windows SDK. The CPU log `out/build-logs/rebuild-amd64-20260919-021219.log` installs these with no ROCm input: `gsthip.dll` + `gsthip-0.dll`, `gstamfcodec.dll`, and `gstd3d11`/`gstd3d12` (plugin + `-1.0-0` library). So the rocm lane adds pins, isolation and a proof, not new code. All of it is gated on `(Get-GpuEnvironment).HasRocm` in `windows/scripts/build/Build-GstreamerFromSource.ps1`. The cpu and nvidia meson lines are byte-identical (`SourceBuild.GstreamerRocm.Tests.ps1`).

| Step | What | Why |
| --- | --- | --- |
| Pins | `-Dgst-plugins-bad:{hip,amfcodec,d3d11,d3d12}=enabled` | `auto` skips a plugin silently when a dependency goes missing; `enabled` fails meson setup. At 1.29.2 `enabled` only turns those skips into errors, and every dependency they need was found on the CPU lane. |
| Isolation | Entries under the ROCm root are dropped from `PATH`, `PKG_CONFIG_PATH`, `PKG_CONFIG_LIBDIR`, `CMAKE_{PREFIX,INCLUDE,LIBRARY,PROGRAM}_PATH`, `INCLUDE` and `LIB`. This lasts from the pkg-config pre-flight through install. `PATH` gets TheRock's `bin` back, appended last, before the phase-9 plugin gate. | Meson does not configure through `Invoke-CmakeConfigure`. Its cmake dependency probe turns `C:\TheRock\build\bin` on `PATH` into the prefix `C:\TheRock\build`, which exposes `lib/cmake/{flatbuffers,llvm,clang,hip*,...}` and `share/cmake/nlohmann_json`. TheRock's `.pc` files (`flatbuffers.pc`, `nlohmann_json.pc`, `rocm_sysdeps` `zlib.pc`/`libzstd.pc`) are reachable through `PKG_CONFIG_PATH`. |
| Proof | After meson setup, `build.ninja` and `meson-info/intro-dependencies.json` are scanned for the ROCm root in backslash, forward-slash and JSON-escaped spelling. A hit or a missing file throws. | A scrub nobody checks is an assumption. |

**HIP is loaded at run time, not linked.** `gst-libs/gst/hip` compiles against in-tree stubs. At 1.29.2 the loader opens the first `HIP_PATH\bin\amdhip64_*.dll`, then `amdhip64_7.dll` by name. It opens hiprtc as `HIP_PATH\bin\hiprtc<MM><mm>.dll`, which is `hiprtc0715.dll` for TheRock 10.0.0 (HIP 7.15). GLib opens both with `LoadLibraryW` by full path. So `amdhip64_7.dll`'s own imports, `rocm_kpack.dll` and `amd_comgr.dll`, resolve only through `PATH` or System32, never through `HIP_PATH\bin`. **TheRock's `bin` has to stay on the image `PATH`.** Measured against the real 10.0.0 gfx120X-all DLLs: amdhip64 exports all 37 names the loader resolves, including `hipGLGetDevices`/`hipGraphicsGLRegisterBuffer`, and hiprtc exports all 7.

**Not enabled: `hip-amd-precompile`.** At 1.29.2, `sys/hip/meson.build` looks only for `hipcc.bin`, and TheRock ships `hipcc.exe`. Upstream fixed this after the tag (`4cdf9d9796`, MR 12331). The hiprtc JIT path already covers the converter kernels, so revisit at the next GStreamer bump.

**Smoke check: `windows/scripts/build/rocm-checks/GStreamer.ps1`.** It is GPU-less and runs through `Test-RocmImage.ps1`. It asserts:
- the HIP runtime above: exports, import closure, and `hiprtc-builtins<MMmm>.dll` on `PATH`;
- per plugin (d3d11, d3d12, amfcodec, hip): the DLL exists; its import closure resolves on `PATH`/System32; no static link to `amdhip64`/`hiprtc`/`amfrt`; and `gst-inspect-1.0 <plugin>` loads it, with a private registry and a 300 s timeout.

What it cannot assert:
- **Elements** (`hipupload`, `hipconvert`, `amfh264enc`, `amfh265enc`). Without an AMD GPU both plugins register 0 elements and still load: hip finds no device, and amfcodec needs `amfrt64.dll` from the Adrenalin driver plus an AMD adapter.
- **Loading hip in any Windows container, on any lane.** `gsthip` is built with GL interop, and `gstgl-1.0-0.dll` imports `OPENGL32.dll`, which Server Core does not ship. The load probe is skipped for that reason; everything else is still checked.
- **Loading amfcodec, when the image `PATH` has no `vulkan-1.dll`.** amfcodec links `gstvulkan`; the same skip applies.

Elements have to be proven on the bare host with the RX 9070 XT: `gst-inspect-1.0 hipconvert`, `amfh265enc`, `d3d12h265dec`. Never bake a GPU-less GStreamer registry into an image: these plugins call no `gst_plugin_add_dependency`.

Not at 1.29.2: `onnxinference` `execution-provider=hip`/`migraphx`/`dml`. They exist only on GStreamer `main` (Aug–Sep 2026, untagged).

Evidence: `subprojects/gst-plugins-bad/{meson.options,gst-libs/gst/hip/{meson.build,gsthiploader.cpp,gsthiprtc.cpp,gsthip-interop.cpp},sys/hip/{meson.build,plugin.cpp},sys/amfcodec/{meson.build,plugin.cpp,gstamfencoder.cpp},gst-libs/gst/d3d1{1,2}/meson.build,sys/d3d1{1,2}/meson.build}` at tag `1.29.2`; the TheRock 10.0.0 tarball listing; the CPU build log's install lines and import-walk summary.

## FFmpeg on the rocm lane: AMD AMF

**What it enables (rocm lane only).**
- Encoders `h264_amf`, `hevc_amf`, `av1_amf`.
- Decoders `h264_amf`, `hevc_amf`, `av1_amf`, `vp9_amf`.
- Filters `vpp_amf` (scaling and colour), `sr_amf` (super resolution), `frc_amf` (frame-rate conversion), and the screen-capture source `vsrc_amf` (configured as `amf_capture`).
- The `amf` hwdevice, which can take a D3D11 or D3D12 child device.

The cpu and nvidia lanes are configured exactly as before.

**None of it uses ROCm.** AMF is AMD's driver-level media SDK, and FFmpeg n9.0.2 has no HIP code at all (the configure script contains no `hip` token). It is tied to the rocm lane by owner decision, not by any technical need. The TheRock tarball carries no AMF files, and FFmpeg needs none from it.

**How.**
- `Build-FfmpegFromSource.ps1` downloads the AMF release's header-only asset, `AMF-headers-<AMF_HEADERS_VERSION>.tar.gz` (84 KB, never the 1.2 GB repo). It is verified against `AMF_HEADERS_SHA256` in `versions.env`, which equals the release asset's GitHub digest.
- The headers are copied into `compat/amf/AMF` in the source tree and configure gets `--enable-amf --extra-cflags=-I<src>/compat/amf`. This is the same route the ONNX Runtime headers already take on this lane.
- `--enable-amf` is explicit, so a missing or too-old header stops configure with `amf requested but not found`. FFmpeg n9.0.2 requires AMF 1.5.2.0 or newer (configure:7902-7904), and the pin is `v1.5.2`.
- After configure, two rocm-only gates fail the stage in minutes rather than at the smoke gate:
  - `ffbuild/config.mak` must enable all 12 AMF symbols;
  - `ffbuild/config.mak` must not name the ROCm tree in any spelling. FFmpeg is not a CMake build, so `-DCMAKE_IGNORE_PREFIX_PATH` does not apply. It is also safe by construction, because `Dockerfile.rocm` sets no `INCLUDE`/`LIB`/`PKG_CONFIG_PATH` and no TheRock executable is one of FFmpeg's build tools.
- The headers are also installed to `C:\runtime\ffmpeg\include\AMF`. Every lane installs `libavutil/hwcontext_amf.h`, which includes `<AMF/core/Factory.h>`; on the rocm lane that header now compiles for consumers.
- Pins travel as build args: `AMF_HEADERS_VERSION` and `AMF_HEADERS_SHA256` go through the media-core map in `Get-MediaBranchVersionArg` into the `media-core-built-ffmpeg` stage. They are excluded from the merge stage. `bump_versions.py` refreshes the SHA whenever the tag moves.

**Smoke check.** `windows/scripts/build/rocm-checks/FFmpeg.ps1`, run by `Test-RocmImage.ps1` under `EXPECT_ROCM=1`. It checks that the image's ffmpeg lists every AMF encoder, decoder, filter and the `amf` hwaccel, and that `--enable-amf` appears in its configuration line. It also checks that the AMF headers are installed and that no `amfrt*.dll` ships in the image. Listing reads FFmpeg's static tables, so no GPU is needed. It does NOT prove that an AMF session opens.

**Limits.**
- **Runtime comes from the host driver.** `amfrt64.dll` belongs to the AMD Adrenalin driver and is never shipped. FFmpeg's Windows `dlopen` searches only the exe directory and System32 (`compat/w32dlfcn.h:134-138`), so PATH does not help.
- **Inside a container: UNVERIFIED.**
  - Microsoft supports only DirectX in Windows containers and lists Server Core images as not supported for GPU acceleration.
  - On this host, container GPU passthrough is blocked by the 26100 image vs 26200 host build skew (docs/windows-build-resources.md).
  - The only community recipe copies the AMF DLLs from `HostDriverStore` into System32, and reports no encode test.
  - Verify on the bare host with the exported `C:\runtime\ffmpeg` instead: `ffmpeg -f lavfi -i testsrc2 -c:v hevc_amf -f null -`.
- **Driver floors:** 10-bit encode needs AMF runtime 1.4.32 or newer (driver 23.30); the decoder's bit-depth detection expects 1.4.36. Per-codec coverage on RX 9070 XT (gfx1201) is UNVERIFIED.
- **Generic encoder lookup differs per lane.** On the rocm lane, looking up an H.264/HEVC encoder by codec id, for example PyAV `add_stream('h264')` or `avcodec_find_encoder`, now returns `h264_amf`/`hevc_amf` instead of `*_d3d12va`, because the AMF encoders are registered first (allcodecs.c:864 before 867, 877 before 880). AV1 (`av1_d3d12va` is registered first) and all decoders are unchanged. The smoke asks for `mpeg4` by name, so it is unaffected.
- **Already on every lane, so not made rocm-only:** D3D11VA/D3D12VA/DXVA2 hwaccels, the `*_d3d12va` encoders and the `*_d3d11`/`*_d3d12` filters. These come in through autodetect, and making them rocm-only would change the cpu and nvidia flags. The ONNX DNN backend's `device=dml` (DirectML) is also already built on every lane.
- **Not enabled:**
  - Vulkan: the SDK is in the base image, but its `Include` is not on INCLUDE, and AMD's Windows Vulkan Video is reported buggy (AMD-Gfx-Drivers#99). Needs a spike.
  - OpenCL: never autodetected. It needs a statically built Khronos ICD loader, because TheRock ships no `OpenCL.lib` and no `cl_d3d11.h`.
  - HIP-native FFmpeg: does not exist upstream.

**License.** The AMF headers are MIT; all 57 files carry the grant, plus AMD's codec-royalty notice. `amf` is in no nonfree or GPL list at n9.0.2 (configure:2029-2064, 2192-2195), so the image's FFmpeg stays `--enable-gpl --enable-version3`, "GPL version 3 or later", with no `--enable-nonfree`.

**Evidence.**
- FFmpeg n9.0.2 at https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.2/ :
  - `configure` (350, 2166, 3597, 3609-3730, 4257-4259, 4799-4801, 7902-7904, 8360-8361);
  - `libavcodec/allcodecs.c` (857-858, 864-865, 877-878, 915);
  - `libavfilter/allfilters.c` (444-446, 570);
  - `libavfilter/vsrc_amf.c` (387-388);
  - `libavutil/hwcontext.c` (91);
  - `compat/w32dlfcn.h` (134-138).
- The AMF v1.5.2 release, https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/tag/v1.5.2 : its asset `AMF-headers-v1.5.2.tar.gz` has digest sha256:d3c12eb3…11c99, and the tag peels to commit eadd00804d5f7e5cd8c85d540073198312870776.
- A real FFmpeg 9.0.2 build with `--enable-amf` lists exactly these names, and the smoke check reports zero listing findings against it.

## OpenCV on the rocm lane

**What the rocm lane adds: nothing new at build time. The AMD path was already there.** OpenCV 5.0.0 has no HIP or ROCm code path. Its GPU paths that work on AMD hardware are all vendor-neutral, and every lane already compiles them:

- **OpenCL T-API:** `WITH_OPENCL=ON`, `WITH_OPENCL_SVM=ON`.
- **D3D11 interop:** `WITH_DIRECTX=ON`.
- **Vulkan backend of the classic dnn engine:** `WITH_VULKAN=ON`.

OpenCL builds against OpenCV's bundled `3rdparty/include/opencl/1.2` headers with no import library. At run time it loads `OpenCL.dll` by bare name through the standard DLL search and requires `clEnqueueReadBufferRect`. The rocm layer supplies a Khronos ICD loader, `C:\TheRock\build\bin\OpenCL.dll`, last on PATH, plus AMD's PAL-based `amdocl64.dll`. That is what gives the T-API a runtime on this lane.

`Build-OpencvFromSource.ps1` changes only on the rocm lane:

- `Get-OpencvRocmCmakeArgs` adds `-DWITH_OPENCLAMDFFT=OFF -DWITH_OPENCLAMDBLAS=OFF`. clBLAS and clFFT default ON upstream and are probed through default paths. They are dormant libraries that neither TheRock nor the image ships. On cpu and nvidia the function returns nothing.
- After configure, `Get-OpencvRocmConfigureFinding` fails the stage before the compile in two cases:
  - the summary lacks `OpenCL: YES`;
  - any line of `opencv-configure.log` names the ROCm root.

  This is the proof that TheRock's `lib/cmake` packages, zlib or OpenBLAS never reached OpenCV.
- `rocm-checks/OpenCV.ps1`, run by `Test-RocmImage.ps1`, re-checks the shipped bytes and needs no GPU:
  - `cv2.getBuildInformation()` reports `OpenCL: YES` with `Link libraries: Dynamic load`;
  - no build-information line names the ROCm tree;
  - an `OpenCL.dll` with the 1.1 entry point loads through the standard DLL search.

  `cv2.ocl.haveOpenCL()` is reported warn-only, because the smoke container has no GPU.

**Choosing the device.** The host exposes a dGPU and an iGPU, so select one with `OPENCV_OPENCL_DEVICE=<platform>:<type>:<name>`, for example `:GPU:gfx1201`. `OPENCV_OPENCL_RUNTIME=<path>` pins a specific loader.

**Not available, and why:**

- **HIP for `cv::cuda`/`cudev` and HIP-in-UMat.** Only unmerged upstream PRs exist, validated on Linux only: opencv#29285/#29527 with contrib #4147/#4178, and opencv#29372.
- **MIGraphX dnn backend** (opencv#29726). It is `NOT UNIX`-guarded, and no Windows MIGraphX exists.
- **RPP HAL** (opencv#29505). Closed unmerged.
- **G-API's ONNX DirectML EP is not compiled on any lane today**, although `WITH_DIRECTML=ON` is set. Two causes:
  - ORT 1.30 installs `dml_provider_factory.h` flat into `include/onnxruntime/` (`cmake/onnxruntime_providers_dml.cmake:82-83`), while OpenCV's `cmake/FindONNX.cmake:93` probes `include/onnxruntime/core/providers/dml/`, so `HAVE_ONNX_DML` stays off.
  - `modules/dnn/CMakeLists.txt:141` tests `HAVE_ONNXRUNTIME`, which FindONNX never sets. So dnn always downloads `onnxruntime-win-x64-1.25.1.zip` (unpinned, no SHA256), FORCE-rewrites `ONNXRT_ROOT_DIR` (`:279`) and re-runs FindONNX (`:287`).

  Evidence: `out/build-logs/rebuild-push-amd64-20260922-034439.log` lines 307666, 308144 and 308502. Fixing it changes the cpu/nvidia outputs too, so it is an owner decision, not a rocm-lane change.
- **GPU inside the container.** Microsoft supports only DirectX in Windows containers, and on this host the 26100/26200 build skew blocks GPU passthrough. Measure the OpenCL T-API on the bare host or on a 26100 host. See [windows-build-resources.md](windows-build-resources.md).

Upstream references, all at the 5.0.0 tag: `cmake/OpenCVDetectOpenCL.cmake`, `modules/core/src/opencl/runtime/opencl_core.cpp`, `CMakeLists.txt:333-344`, and TheRock's `win-tarball-list` (`bin/OpenCL.dll`, `bin/amdocl64.dll`; no `clAmd*`).

## IREE and TVM on the rocm lane

The ROCm layer (`Dockerfile.rocm`) sits in the sdk slot, so `media-tvm` sees `GPU_TYPE=rocm` and TheRock at `C:\TheRock\build`. What that turns on:

| Component | rocm lane | cpu / nvidia |
| --- | --- | --- |
| IREE runtime | HIP HAL driver (`-DIREE_HAL_DRIVER_HIP=ON`, `-DIREE_ROCM_TEST_TARGET_CHIP=` so the rocminfo probe is skipped) | unchanged |
| IREE compiler | `rocm` target (`-DIREE_TARGET_BACKEND_ROCM=ON`: AMDGPU in IREE's in-tree LLVM, linked by `iree-lld`) | unchanged |
| TVM runtime | `USE_OPENCL=ON` (TVM's lazy `OpenCL.dll` loader, no SDK) | `USE_OPENCL=OFF` |
| TVM ROCm spike (`TVM_ROCM=1`; `-NoRocmSpikes` passes 0) | AMDGPU in TVM's minimal LLVM, `USE_ROCM=C:/TheRock/build`, `tvm_runtime_rocm.dll` on HIP | off |

**IREE needs nothing from TheRock at build time.** The HIP headers are vendored (`third_party/hip-build-deps`, HIP 6.1), so the configure keeps the rocm-lane package-prefix isolation. Two carried details:

- **The DLL name.** IREE's Windows HIP driver dlopens only `amdhip64.dll`, but TheRock 10 and Adrenalin ship `amdhip64_7.dll` / `amdhip64_6.dll`. Without a fix the driver reports UNAVAILABLE on every AMD host. `Build-IreeFromSource.ps1` patches the name list to try `_7`, then `_6`, then the legacy name. TheRock's `amdhip64_7.dll` exports all 72 required symbols (checked 2026-09-23). Upstream candidate: iree-org/iree `runtime/src/iree/hal/drivers/hip/dynamic_symbols.c`.
- **The device bitcode.** The rocm target downloads ocml/ockl at CONFIGURE time from shark-infra/amdgpu-device-libs v20231101, hash-pinned in IREE's own CMake. `IREE_ROCM_DEVICE_BC_SHA256` in versions.env mirrors that pin (`bump:hold`, slaved to `IREE_VERSION`). The build refuses to run when the two differ, or when upstream stops pinning. An IREE bump that moves the archive fails the rocm lane until someone re-derives the pin from `compiler/plugins/target/ROCM/CMakeLists.txt`.

**TVM's `find_rocm` runs even with `USE_ROCM=OFF`.** It reads `$env:ROCM_PATH` and puts TheRock's `include\` (flatbuffers, nlohmann, CL, half, thrust, getopt.h) and `__HIP_PLATFORM_AMD__` on every translation unit. So without the spike, `Build-TvmFromSource.ps1` hides `ROCM_PATH` for the whole script, configure and scikit-build re-configure alike, then restores it.

**The spike** carries two patches:

- `rocm_device_api.cc` has no HSA on Windows: `kExist` asks `hipGetDeviceCount`.
- `python/tvm/support/rocm.py` gets four Windows fixes:
  - `ld.lld` is found via PATHEXT, then `ROCM_PATH\lib\llvm\bin` by absolute path;
  - the bitcode comes from `HIP_DEVICE_LIB_PATH`;
  - the pre-2023 `oclc_daz_opt_*` and `oclc_correctly_rounded_sqrt_*` files are optional (TheRock does not ship them, ROCm/TheRock#5448);
  - a missing `rocminfo` falls back instead of raising.

`llvm-config` must never resolve into the ROCm tree, and must report AMDGPU.

**Compile only, no GPU.** A Windows container gets no HIP compute, so both gates compile and list:

- The build gates check that `iree-compile` targets hip gfx1201, that `--list_drivers` shows `hip`, and that `import tvm` loads the OpenCL and ROCm sidecars.
- The smoke checks `windows/scripts/build/rocm-checks/IREE.ps1` and `TVM.ps1` re-check the image. They assert a linked ELF64 AMDGPU code object with `EF_AMDGPU_MACH` 0x4E (gfx1201) from IREE (CLI and python) and from TVM's own AMDGPU codegen. They read `C:\runtime\lib\tvm\ROCM-FEATURES.txt` to know whether the spike ran.

**Running on a host.** Kernels execute only on a host with AMD's driver and an RDNA3/4 GPU; IREE 3.11 rejects gfx1030/gfx1036. Python ≥3.8 does not search `PATH` for DLLs, so TVM's ROCm sidecar needs `amdhip64_7.dll` in System32 (the driver's copy) or a registered DLL directory.

**Not enabled, on purpose:**

| Feature | Why |
| --- | --- |
| IREE `amdgpu` HAL driver | needs HSA/ROCR, which Windows ROCm does not ship |
| TVM hipBLAS | not now |
| TVM rocThrust | forces hipcc/AMD clang as CXX |
| TVM RCCL | not in TheRock 10 for Windows |

Evidence: the research JSON (component "Apache TVM + IREE"). Pinned sources are IREE e4a3b04 (v3.11.0) and TVM 994e0216.

## LiteRT-LM GPU backend (rocm lane only)

**What it enables.** On `-Variant rocm`, `C:\runtime\lib\litert-lm\bin` also carries LiteRT-LM's Windows GPU runtime, so `litert_lm_main.exe --backend=gpu` can run:
- `libLiteRtWebGpuAccelerator.dll` (LiteRT's WebGPU accelerator; a closed-source prebuilt from the Apache-2.0 LiteRT-LM repo);
- `libLiteRtTopKWebGpuSampler.dll`;
- `libwebgpu_dawn.dll` (Dawn, which runs on Direct3D 12);
- DXC's `dxcompiler.dll` and `dxil.dll`.

DXC's licence texts go to `C:\runtime\lib\litert-lm\licenses\directx-shader-compiler\`.

This feature does **not** use ROCm or HIP. For Windows, Google ships only the WebGPU accelerator: no HIP, Vulkan or OpenCL one (`litert/runtime/accelerators/gpu_registry.cc`). D3D12 is also the only GPU API that Windows containers accelerate. It is on the rocm lane by owner decision, but it works on any vendor's GPU.

**How.** `windows/scripts/build/Build-LitertLmBazel.ps1` gates on `GPU_TYPE=rocm`, the same test as `Get-GpuEnvironment`'s `HasRocm`:
1. **[3/6]:** LiteRT-LM's `WORKSPACE` must pin the DXC zip at `LITERT_LM_DXC_ZIP_SHA256`.
2. **[4/6]:** the ROCm tree is hidden from Bazel before its server starts. Every env entry under `ROCM_PATH`/`HIP_PATH` is unset or filtered out of list variables (PATH, `HIP_PATH`, `ROCM_PATH`, `HIP_DEVICE_LIB_PATH`, `LLVM_PATH`, and any list var). `HIP_PLATFORM` is unset too. The script restores all of it in its `finally` block. Bazel does not go through `Invoke-CmakeConfigure`, so this is its equivalent of `CMAKE_IGNORE_PREFIX_PATH`.
3. **[5/6]:** one extra target, `@directx_shader_compiler//:dxc_dlls`. Bazel fetches it and checks it against LiteRT-LM's own `WORKSPACE` sha256.
4. **[6/6]:** the script copies these files into `C:\runtime\lib\litert-lm`:
   - the three prebuilt DLLs from `C:\llm\prebuilt\windows_x86_64` (git-LFS), each checked against its versions.env SHA256 first;
   - the DXC DLLs and licences from `C:\bzl\external\directx_shader_compiler`.

On cpu and nvidia, the Bazel command stays `build //runtime/engine:litert_lm_main --config=windows --repo_env=ANDROID_NDK_VERSION=`, the env is not touched, and no file is added.

**Pins.** Four keys in `linux/scripts/01-core/versions.env`, all tied to `LITERT_LM_VERSION`:
- `LITERT_LM_WEBGPU_ACCELERATOR_SHA256`, `LITERT_LM_WEBGPU_SAMPLER_SHA256` and `LITERT_LM_WEBGPU_DAWN_SHA256`: the git-LFS oids of `prebuilt/windows_x86_64/*.dll` at the tag;
- `LITERT_LM_DXC_ZIP_SHA256`: equal to the GitHub release digest of `dxc_2026_02_20.zip` in DXC v1.9.2602.

`bump_versions.py` (`spec_litert_lm`, under `--write-all`) refreshes all four together with the version. They reach the branch through `Get-MediaBranchVersionArg media-litert` and the ARG+ENV in `media-litert-env`. They never reach the merge stage.

**Smoke.** `windows/scripts/build/rocm-checks/LiteRtLm.ps1` runs from `Test-RocmImage.ps1` with `EXPECT_ROCM=1` and needs no GPU. It checks:
- the files are present;
- each DLL loads in a child pwsh whose PATH is only the bin dir plus System32, and its entry export resolves (`LiteRtAcceleratorImpl`, `LiteRtTopKWebGpuSampler_Create`, `wgpuCreateInstance`, `DxcCreateInstance`);
- `--help` lists `--backend`.

**Limits.**
- **No GPU run has been proven.** GPU in a Windows container needs process isolation plus `--device class/5B45201D-F2F2-4F3B-85BB-30FF1F953599`. That passthrough is blocked on this host by the build skew (`docs/windows-build-resources.md`). Microsoft also lists Server Core base images as unsupported for GPU acceleration.
- On the bare host, any D3D12 driver (AMD, NVIDIA or Intel) should work; upstream supports that path.
- It is unverified whether Dawn accepts the WARP adapter a container can see.
- Upstream `--backend` defaults to `gpu`. On the cpu and nvidia images, pass `--backend=cpu`.
- Microsoft's DXC licence terms apply to redistributing `dxil.dll` and `dxcompiler.dll`.

**Evidence** (all at the pinned versions):
- LiteRT-LM v0.17.1: `README.md:141-144`; the `prebuilt/windows_x86_64` tree; `WORKSPACE:564-570` and `BUILD.directx_shader_compiler`; `runtime/components/sampler_factory.cc:469-482`; `runtime/engine/BUILD` (litert_lm_main exports `LiteRt*` via `windows_exported_symbols.def`); `runtime/engine/litert_lm_main.cc:55` (`--backend` default `gpu`).
- LiteRT@9fe5be45 (LiteRT-LM's pin): `litert/runtime/accelerators/gpu_registry.cc`; `litert/c/litert_common.h` (`LITERT_HAS_WEBGPU_SUPPORT_DEFAULT 1`).
- DXC: https://github.com/microsoft/DirectXShaderCompiler/releases/tag/v1.9.2602 (asset digest `sha256:a1e89031…`).
- https://developers.google.com/edge/litert/next/gpu
- https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/gpu-acceleration

## PyTorch on the rocm lane (torch stage)

The rocm image's app venv (`C:\opt\OrchestrANT\.venv`) runs **AMD's PyTorch for Windows ROCm**. It has torch 2.13.0+rocm10.0.0 and torchvision 0.28.0+rocm10.0.0 (cp314, win_amd64), the `rocm[libraries]` 10.0.0 runtime and the gfx1201 (RDNA4, RX 9070 XT) device wheels. The cpu and nvidia images are unchanged.

**How it is selected.** `windows/Dockerfile.torch` declares a global `ARG TORCH_ROCM=0` and ends with `FROM rocm-${TORCH_ROCM}`:

- `app` is the old single stage, unchanged: `uv sync` with `PYTORCH_EXTRA=pytorch-cpu`, so the app lock resolves the same way on every lane.
- `rocm-0` is `app` with no instruction of its own. This is what cpu and nvidia build, with the same cache key and layers as before.
- `rocm-1` is built only when the driver passes `TORCH_ROCM=1`. That happens on the rocm lane only (`Get-BkRocmStageArg`).

`rocm-1` runs `windows/scripts/build/Install-TorchRocm.ps1`, then `Build-TorchApp.ps1 -Mode verify`, so the app's own smoke suite runs on the ROCm torch.

**What the installer does.**

- **Pins.** Ten files are pinned by URL + SHA256 in `versions.env` (`TORCH_ROCM_WINDOWS_<NAME>_URL` / `_SHA256`, next to `ROCM_WINDOWS_*`). They reach the stage as ARG defaults that `sync_versions.py` keeps in step. AMD publishes no hashes and its index carries no `#sha256=` fragments, so every SHA256 is self-measured (`curl -fL <url> | sha256sum`). The URLs are AMD's final addresses (`stable.repo.amd.com/rocm/pytorch/whl-next/…`, `/rocm/core/whl-next/…`).
- **Coupling, checked at build time.** Every file except `rocm-bootstrap` must be built for `ROCM_WINDOWS_RELEASE`. The device wheels must name one GPU and match their package's version. The venv must be `cp314`. The app lock's torch/torchvision must be the same release as the pins, so an `APP_REF` that moves torch fails the stage until the pins move too. **Bump the whole `TORCH_ROCM_WINDOWS_*` block with `ROCM_WINDOWS_RELEASE`.**
- **Offline install.** Files are cached by hash on the torch stage's uv cache mount (`C:\uvcache\torch-rocm\<sha256>\<file>`, about 1.5 GB) and re-hashed before reuse. The install is `uv pip install --force-reinstall --no-deps --no-index --no-build-isolation --require-hashes`. No index is contacted and nothing is resolved. The `rocm` sdist builds on the venv's setuptools (83.0.0 from the app lock).
- **The no-GPU trap.** The `rocm` sdist's `setup.py` calls `offload-arch` to choose a GPU family. The build container has no GPU, and TheRock's `offload-arch.exe` is on PATH. The installer sets `ROCM_SDK_TARGET_FAMILY=gfx1201` for the install. `ROCM_BOOTSTRAP_DISABLE_DETECTION=1` is also set; `rocm-bootstrap` 0.1.0 detects only inside its installer plugin, which `--no-deps` never runs.
- **Dependency confusion.** PyPI has an unrelated `rocm` 0.1.0 and `rocm-bootstrap` 0.3.0. Pinning by URL + hash rules both out.

**Smoke.** `windows/scripts/build/rocm-checks/Torch.ps1` runs under `Test-RocmImage.ps1` (`EXPECT_ROCM=1`) and at the end of the install. It imports torch/torchvision/rocm_sdk without a GPU and asserts:

- `+rocm<release>` builds of torch and torchvision
- a non-empty `torch.version.hip`
- `torch.version.rocm` and `rocm_sdk` equal to the release
- the runtime and device packages at matching versions

It never calls `torch.cuda`, and `torch.cuda.is_available()` is False in the container by design.

**Limits.**

- GPU compute is not proven by the image. The bare-host check (torch matmul on the GPU vs CPU, above) still applies. The upstream TheRock#8379, open, reports zeros from torch on RX 9070 XT with ROCm 7.14.
- There is no Windows triton wheel, so GPU `torch.compile`/inductor is unavailable.
- The wheels carry their own ROCm 10.0.0 runtime (`_rocm_sdk_core`/`_rocm_sdk_libraries` in the venv, about 4 GB installed). It is the same release as `C:\TheRock\build`, but it is a second copy.
- The CPU torch installed by `uv sync` stays as dead bytes in the `app` layer, about 0.5 GB. That is the cost of leaving the cpu/nvidia stage untouched.
- The rocm lane runs the app verify twice (CPU torch, then ROCm torch), about 1–2 minutes extra.
- `whl-next` is AMD's only Windows channel. A withdrawn file fails the download loudly; a cached copy keeps working.

**Evidence** (2026-09-23, Windows 11 host, CPython 3.14.7, uv 0.12.7):

- All ten files downloaded and hashed; sizes match `Content-Length`. The torch wheel is 113,446,960 bytes; rocm-sdk-core is 758,050,981.
- The offline install replaced a CPU torch/torchvision in 59 s with the rocm-check clean.
- `import torch` reports `2.13.0+rocm10.0.0 hip 7.15.26333 rocm 10.0.0`.
- The app smoke's CPU ops pass with `HIP_VISIBLE_DEVICES=-1` (0 devices).
- `amdhip64_7.dll` statically imports only system DLLs plus `amd_comgr`/`rocm_kpack`. The driver is loaded at run time, which is why `import torch` needs no GPU.

Tests: `windows/scripts/tests/Torch.Rocm.Tests.ps1`.

## llama.cpp HIP (`Dockerfile.rocm-llama`, rocm lane only)

**What it adds.** The rocm image carries llama.cpp's official Windows ROCm/HIP release. The pinned build is b11115, asset `llama-b11115-bin-win-rocm-10.0-x64.zip`. It lives in `C:\runtime\opt\llama.cpp-hip`, which `LLAMA_CPP_HIP_HOME` names. It contains:
- `llama-server.exe`, `llama.exe` and the other tools;
- the CPU `ggml-cpu-*.dll` variants;
- `ggml-hip.dll`, 973 MB, with device code for 20 GPUs from gfx1010 to gfx1201.

Upstream builds this zip against the same TheRock 10.0.0 release the rocm sdk installs (release.yml `windows-rocm` job, pip `rocm[libraries,devel]==10.0.0`). Nothing is compiled here, so AMD's clang is not involved.

**Where it sits.** base → sdk (rocm) → toolchain → media → [migraphx] → **llama** → torch → final. The stage is `Dockerfile.rocm-llama`, target `built`; its three pins are forwarded by `Build-Buildkit.ps1`. `-NoRocmSpikes` builds it directly on the merged media.

**How it is installed** (`windows/scripts/build/Install-LlamaCppHip.ps1`). The script fails closed:
- It runs only when `Get-GpuEnvironment` reports `HasRocm`, and only when ROCm's bin has `amdhip64_7.dll`, `hipblas.dll` and `rocblas.dll`.
- The asset's build number must equal `LLAMA_CPP_HIP_BUILD`, and its `rocm-X.Y` must equal `ROCM_WINDOWS_RELEASE`'s major.minor.
- The zip is verified against `LLAMA_CPP_HIP_SHA256`.
- The zip must be flat, must hold the load-bearing files, and may shadow no ROCm DLL except the HIP runtime.

The script then writes `llama-cpp-hip-manifest.json` (size and SHA256 of every file). The same RUN then runs `rocm-checks\LlamaCpp.ps1`, so a bad pin fails this stage.

**Which DLLs load from where.**
- **HIP runtime, from the llama directory.** `amdhip64_7.dll`, `rocm_kpack.dll` and `amd_comgr.dll` sit next to the exes. This is upstream's workaround: the Adrenalin driver's System32 `amdhip64_7.dll` otherwise wins the loader search (llama.cpp#26929).
- **Math libraries, from ROCm's bin.** hipBLAS, rocBLAS, hipBLASLt and their kernel directories load from `C:\TheRock\build\bin`, which is last on PATH.
- **Never on PATH.** The llama directory stays off PATH, because its HIP runtime would otherwise shadow ROCm's for every process.

Measured 2026-09-23:
- The three bundled DLLs are the same bytes as TheRock 10.0.0 gfx120X-all's (amdhip64_7 SHA256 `546fb3d6…`, rocm_kpack `97b59ca4…`, amd_comgr same size and CRC32).
- ggml-hip.dll imports 10 hipBLAS and 50 HIP functions, and TheRock's DLLs export all of them.

So one HIP runtime serves the whole process, and there is no version skew.

**What the smoke check proves** (`windows/scripts/build/rocm-checks/LlamaCpp.ps1`). It runs with no GPU:
- the shipped bytes equal the pinned zip's;
- the directory is not on PATH;
- the HIP runtime is ROCm's own bytes;
- every static import of ggml-hip.dll resolves, transitively, to the right directory and exports what is imported;
- ggml-hip has device code for every GPU that ROCm's rocBLAS has kernels for;
- `llama-server --version` reports the pinned build.

`--version` loads no ggml backend, because the argument parser exits before `ggml_backend_load_all()`. It therefore needs neither a GPU nor HIP.

**Limits.**
- **Nothing proves a kernel runs.** Microsoft accelerates only DirectX inside Windows containers, and GPU passthrough on this host is blocked by the 26100/26200 build skew (see [windows-build-resources.md](windows-build-resources.md)).
- **RDNA4 only.** The gfx120X-all tarball ships rocBLAS/hipBLASLt kernels only for gfx1200 and gfx1201. On any other AMD GPU (for example a gfx1036 iGPU), the hipBLAS paths fail at runtime even though ggml-hip has device code for it.
- **Driver floor unknown.** The minimum Adrenalin driver for TheRock 10.0.0's HIP 7.15 runtime is not known.
- **Size.** About +1.24 GB and +1 layer. About 138 MB of that is the bundled runtime duplicating ROCm's own copy.
- **Pinning.** Upstream publishes several builds a day, all flagged prerelease. Renovate reports new builds (approval-gated). `python docs/scripts/bump_versions.py --write-all` moves the build, the asset name and its SHA256 together. The stable release v0.4.1 names build b10964, which also has a win-rocm-10.0 zip.

**Evidence.**
- https://github.com/ggml-org/llama.cpp/releases/tag/b11115
- https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/.github/workflows/release.yml (`windows-rocm` job, lines 978-1136)
- https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/.github/actions/windows-setup-rocm/action.yml
- https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/common/arg.cpp (`--version` handler) and tools/server/server.cpp (`llama_server` start-up order)
- https://github.com/ggml-org/llama.cpp/issues/26929

## MIGraphX and the ORT plugin EP (rocm lane, spike)

`-Variant rocm` builds `windows/Dockerfile.rocm-migraphx` (target `built`) on the merged rocm media, before the llama stage. `-NoRocmSpikes` skips it. cpu and nvidia never solve it, and no other Dockerfile or media build-arg map carries its pins.

What it produces:

| Path | Contents |
|---|---|
| `C:\runtime\lib\migraphx` (`MIGRAPHX_ROOT`) | AMD MIGraphX 2.17.0 (tag `rocm-10.0`, pinned by commit) built from source: `bin\migraphx*.dll`, `migraphx-driver.exe`, `migraphx-hiprtc-driver.exe`, `lib\cmake\migraphx`, headers |
| `C:\runtime\lib\onnxruntime-ep-amdgpu` (`ORT_AMDGPU_EP_ROOT`) | AMD's out-of-tree ONNX Runtime plugin EP `migraphx-ep.dll` ([onnxruntime/onnxruntime-ep-amdgpu](https://github.com/onnxruntime/onnxruntime-ep-amdgpu), commit on `gpuep-releases/gpuep-rel-2611`), built against the image's ORT 1.30.0, with its MIGraphX closure and TheRock's `amdhip64_7`/`amd_comgr`/`hiprtc*` beside it |

ORT and GenAI themselves are byte-identical on every lane. The EP is loaded at run time with `onnxruntime.register_execution_provider_library(<name>, r"C:\runtime\lib\onnxruntime-ep-amdgpu\migraphx-ep.dll")`.

How it is built (`Build-MigraphxFromSource.ps1`, `Build-OrtAmdgpuEpFromSource.ps1`, helpers in `WindowsMigraphx.Common.psm1`):

- **Two compilers, on purpose.** MIGraphX has HIP device code, and the hub's clang-cl has no AMDGPU backend. MIGraphX therefore compiles with TheRock's `lib\llvm\bin\clang++.exe`, passed by absolute path; `lib\llvm\bin` never goes on PATH. Its host-only deps (abseil 20250512.0, protobuf v30.0, msgpack-c cpp-3.3.0, SQLite 3.50.4) build with clang-cl, as upstream's Windows CI does. The EP is host-only C++ and builds with clang-cl.
- **Targets are explicit.** `GPU_TARGETS` comes from `ROCM_WINDOWS_GFX_FAMILY` (`gfx120X-all` = `gfx1200;gfx1201`), never from a host probe.
- **Configuration no upstream CI builds.** rocMLIR is not in the TheRock tarball, so `MIGRAPHX_ENABLE_MLIR=OFF`. That costs the rocMLIR fusions (performance, not correctness). Also used: `BUILD_DEV=OFF` (hiprtc JIT), composable_kernel off, CMake 4.4.3, TheRock 10.0. Upstream's only Windows CI is build-only: gfx942, `BUILD_DEV=On`, ROCm 7.13.
- **CRT.** MIGraphX and its deps are `/MD`. The EP is `/MT`, as upstream forces it; it talks to ORT and MIGraphX only through C APIs.
- **Supply chain.** Every archive is SHA256-pinned in `versions.env` (`MIGRAPHX_WINDOWS_*`, `ORT_AMDGPU_EP_*`). The EP declares 8 FetchContent URLs (11 with DirectML) with no `URL_HASH`. Each one is pre-seeded through `FETCHCONTENT_SOURCE_DIR_*` from a verified archive, and so is the abseil that protobuf v34.1 fetches. The build refuses when the pinned commit declares a URL no pin rebuilds byte-for-byte, and `FETCHCONTENT_FULLY_DISCONNECTED` with CMP0170 turns any other fetch into a configure error.
- **Isolation.** The deps configure with the rocm-lane `CMAKE_IGNORE_PREFIX_PATH`. MIGraphX and the EP pass `-AllowRocmPrefix`, because they need hip, MIOpen, rocBLAS, hipBLASLt and hiprtc from TheRock.

Smoke (`windows/scripts/build/rocm-checks/MIGraphX.ps1`, GPU-less) checks:

- both trees are complete;
- every static import of a MIGraphX-built PE resolves beside it, in `HIP_PATH\bin` or in System32;
- the TheRock HIP runtime set sits beside the EP, byte-identical;
- `amdhip64` is only delay-imported;
- `migraphx-ep.dll` loads (`LoadLibraryEx`) and exports `CreateEpFactories` without starting HIP.

It does **not** call `RegisterExecutionProviderLibrary`. The EP's `GetSupportedDevices` calls `hipGetDeviceCount()` first, so registration needs a HIP device ([mgx_factory.cc](https://github.com/onnxruntime/onnxruntime-ep-amdgpu/blob/99ab5cb43caa421e0b19870fa4ce9323117e5e56/src/migraphx/mgx_factory.cc)), and Windows containers get DirectX only.

Limits:

- **Run it on the bare host.** Put `%HIP_PATH%\bin` on PATH, or copy the TheRock tree. The EP directory holds the load closure; MIOpen, rocBLAS, hipBLASLt and `rocm_kpack.dll` with their kernel payloads stay in TheRock's `bin`.
- **Prove it against CPU output.** Compare against ORT's CPU EP (TheRock#8379: zeros on gfx1201).
- **Redistribution is open.** The bundled `amdhip64_7.dll` carries the same open redistribution question as the rest of the TheRock tree (see [Redistribution](#redistribution)).
- **GenAI is not wired.** onnxruntime-genai's AMDGPU EP (v0.16.0+) needs the `amdgpu-ep.dll` umbrella (`-DUSE_AMDGPU=ON`, which renames the MIGraphX backend to `migraphx-backend.dll`). It is not built here.

Evidence:

- [AMDMIGraphX rocm-10.0 CMakeLists/requirements/windows.yaml](https://github.com/ROCm/AMDMIGraphX/tree/rocm-10.0)
- [onnxruntime-ep-amdgpu src/CMakeLists.txt@99ab5cb](https://github.com/onnxruntime/onnxruntime-ep-amdgpu/blob/99ab5cb43caa421e0b19870fa4ce9323117e5e56/src/CMakeLists.txt)
- [src/migraphx/CMakeLists.txt (/DELAYLOAD, POST_BUILD closure)](https://github.com/onnxruntime/onnxruntime-ep-amdgpu/blob/99ab5cb43caa421e0b19870fa4ce9323117e5e56/src/migraphx/CMakeLists.txt)
- [src/shared/CMakeLists.txt (HIP DLL list without amd_comgr.dll)](https://github.com/onnxruntime/onnxruntime-ep-amdgpu/blob/99ab5cb43caa421e0b19870fa4ce9323117e5e56/src/shared/CMakeLists.txt)
- [ORT v1.30.0 CMake package install](https://github.com/microsoft/onnxruntime/blob/v1.30.0/cmake/CMakeLists.txt)
- [TheRock ml-libs MIOPEN_USE_MLIR=OFF](https://github.com/ROCm/TheRock/blob/therock-10.0/ml-libs/CMakeLists.txt)
- [AMDMIGraphX#4252](https://github.com/ROCm/AMDMIGraphX/issues/4252)

## Redistribution

The TheRock tree ships licence notices for its libraries under `share\doc`: MIT (rocBLAS,
hipBLASLt, MIOpen, rocFFT, rocRAND, rocSPARSE, hipcc, ...), BSD (rocSOLVER, hipCUB) and
Apache-2.0 (rocThrust; LLVM with the LLVM exception). The HIP runtime (`amdhip64_7.dll`,
`hiprtc*`) and the OpenCL runtime (`OpenCL.dll`, `amdocl64.dll`) ship **without** a
licence file, and the Windows HIP runtime links AMD's prebuilt PAL. The PyTorch wheels
and the llama.cpp zip carry copies of the same runtime. Whether that runtime may ship in
a **public** image is an owner decision to take before `:winamd64-rocm` is pushed;
`docs/deps/deps.json` records it as `LicenseRef-Proprietary-EULA` until then.

## Open points

- **HIP inside a Windows container** is unproven and cannot be measured on this host
  (build skew). GStreamer's `gsthip` cannot load in any Server Core container on any lane
  at all: it links `gstgl`, which imports `OPENGL32.dll`.
- **GPU correctness:** upstream TheRock#8379 reports torch+ROCm returning zeros on the
  RX 9070 XT. Compare every GPU path against its CPU result on the bare host.
- **The spikes are first builds.** MIGraphX with `MLIR=OFF`, `BUILD_DEV=OFF`, gfx120X and
  TheRock 10 is a configuration no upstream CI builds; TVM's ROCm runtime includes
  TheRock's HIP headers from clang-cl for the first time.
- **Found on every lane, not fixed here (owner decision):** OpenCV 5.0.0's dnn module
  downloads `onnxruntime-win-x64-1.25.1.zip` at configure time, unpinned and without a
  SHA256, and links it instead of the chain's ORT. LiteRT-LM is cloned by tag, not by
  commit.
