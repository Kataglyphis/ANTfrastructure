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
| GPU API loaders (sdk layer) | TheRock's `amdocl64.dll` registered as an OpenCL ICD; LunarG's Khronos `vulkan-1.dll` in System32 | OpenCL, Vulkan | OpenCL: TheRock's ICD |
| GStreamer 1.29.2 | `hip`, `amfcodec`, `d3d11`, `d3d12` pinned `enabled` (already built by `auto` on every lane) | HIP (dlopen), AMF, D3D | hip: at run time |
| FFmpeg n9.0.2 | AMF encoders, decoders, filters, `amf` hwdevice; Vulkan hwdevice, 9 hwaccels, 5 encoders, 18 filters, swscale's SPIR-V backend | AMF (driver), Vulkan (loader dlopened at run time) | no |
| OpenCV 5.0.0 | OpenCL T-API (already on every lane); clBLAS/clFFT probes pinned off | OpenCL | TheRock's ICD loader + the registered `amdocl64.dll` ICD |
| IREE | HIP HAL driver, `rocm` compiler target (gfx1201) | ROCm/HIP | at run time |
| TVM | OpenCL runtime; ROCm codegen + runtime as a **spike** (`TVM_ROCM=1`), on a minimal LLVM of its own that carries AMDGPU | OpenCL, ROCm/HIP | spike: yes |
| LiteRT-LM | GPU backend (WebGPU over Dawn on D3D12) | D3D12 | no |
| ONNX Runtime | CPU + DirectML, plus the in-tree WebGPU EP as a **spike** (`ORT_WEBGPU=1`). ORT >= 1.23 has no ROCm EP | DirectML, WebGPU (Dawn on D3D12) | no |
| PyTorch | torch 2.13.0+rocm10.0.0, torchvision 0.28.0+rocm10.0.0, device kernels for gfx1201 and gfx1200 | ROCm/HIP (own runtime in the wheels) | no |
| App venv LiteRT | `ai-edge-litert` 2.2.0 with its WebGPU accelerator | WebGPU (Dawn on D3D12) | no |
| llama.cpp HIP | official Windows ROCm build b11115 (`ggml-hip`), `C:\runtime\opt\llama.cpp-hip` | ROCm/HIP | hipBLAS/rocBLAS |
| llama.cpp Vulkan | the same build's official Windows Vulkan zip (`ggml-vulkan`), `C:\runtime\opt\llama.cpp-vulkan` | Vulkan (the sdk layer's loader) | no |
| MIGraphX + ORT plugin EP | MIGraphX 2.17.0 from source, `migraphx-ep.dll` as a **spike** | ROCm/HIP | yes |

`-NoRocmSpikes` drops the three spikes: the migraphx stage, `TVM_ROCM` and `ORT_WEBGPU`.

Every ONNX Runtime on this lane is the chain's own build, like on every other lane
([`onnxruntime-single-source.md`](onnxruntime-single-source.md)). The WebGPU EP is
built into it, not installed from PyPI.

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
  `TVM_ROCM=0` instead of `1` to media-tvm and `ORT_WEBGPU=0` instead of `1` to the onnx
  stage of media-core.
- These build-args are sent on the rocm lane only (`Get-BkRocmStageArg`):
  - `TVM_ROCM` to media-tvm;
  - `ORT_WEBGPU` plus the five `ORT_WEBGPU_WINDOWS_*` pins to `media-core-built-onnx`
    (the pins also go under `-NoRocmSpikes`, where nothing reads them);
  - `EXPECT_ROCM_SPIKES` to the smoke gate;
  - `TORCH_ROCM=1` plus every `TORCH_ROCM_WINDOWS_*` pin to `Dockerfile.torch`.

  The consumers declare them with default `0` or valueless, so the cpu and nvidia solves
  receive nothing new. The rocm sdk stage alone also gets `VULKAN_VERSION` and
  `VULKAN_RT_WINDOWS_ZIP_SHA256`, and the llama stage `LLAMA_CPP_VULKAN_SHA256`.
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

ORT builds the cpu lane's feature set plus DirectML on this lane and logs `ROCm layer present:
CPU+DML ORT`. The WebGPU spike adds its EP on top ([§ ONNX Runtime WebGPU EP](#onnx-runtime-webgpu-ep-rocm-lane-spike)).
ORT >= 1.23 has no ROCm EP, and the dead `onnxruntime_USE_ROCM` branch was deleted.

**The app venv's ORT is checked on every amd64 lane, rocm included.** Smoke section 21
requires that `C:\opt\OrchestrANT\.venv`'s onnxruntime lists `DmlExecutionProvider` and
that its GenAI reports `is_dml_available()`. It also requires that the venv's onnxruntime
is the chain wheel: the only owner of the package, the chain version, and every
`.pyd`/`.dll` byte-identical to `C:\runtime\wheels\onnxruntime-*.whl`. Both are
compiled-in facts, so no device is needed. The bytes matter because PyPI also ships
onnxruntime 1.30.0 for cp314 win_amd64, without DirectML.

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
backend, so TVM's ROCm spike builds an LLVM of its own ([§ IREE and TVM](#iree-and-tvm-on-the-rocm-lane)).
Host-only HIP consumers stay on clang-cl.

**Smoke gate.** It runs the CPU suite and floor (170), then `Test-RocmImage.ps1` (`EXPECT_ROCM=1`):
1. the env contract;
2. no CUDA;
3. AMD's LLVM not shadowing `clang-cl`/`clang`/`lld-link`;
4. `.info\version` matching the pin;
5. device bitcode present;
6. a `hipcc` compile for gfx1201;
7. every `windows/scripts/build/rocm-checks/*.ps1`, sorted by name;
8. then MIGraphX presence and TVM's `TVM_ROCM` marker matching `EXPECT_ROCM_SPIKES`, the
   mode the driver passed (`OrtWebGpu.ps1` does the same for `ORT_WEBGPU`).

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
`Rocm.Install.Tests.ps1` fails if either rule, or the Vulkan loader's placement below, is
broken.

**OpenCL ICD and Vulkan loader (sdk layer, since 2026-09-23).** Two runtime pieces make the
AMD GPU APIs loadable in the image. Neither needs a GPU to check, and
`rocm-checks/GpuLoaders.ps1` checks both.

- **OpenCL ICD.** TheRock's `bin\OpenCL.dll` is the Khronos ICD loader (built from ROCm
  clr's `opencl/khronos/icd`). It loads the vendor ICDs listed under
  `HKLM\SOFTWARE\Khronos\OpenCL\Vendors`. `Install-Rocm.ps1` registers
  `C:\TheRock\build\bin\amdocl64.dll` there, as `REG_DWORD 0` in the 64-bit view. Until
  then nothing registered it, so the loader found no platform. The loader rules, read at
  the rocm-systems commit therock-10.0 pins (6b0e43f):
  - the value name is the DLL path, passed to `LoadLibraryA` as is, and only DWORD 0
    counts (`icd_windows.c:117-151`);
  - `OCL_ICD_FILENAMES` is no substitute: it is read through `secure_getenv`, which
    returns nothing in an elevated process (`icd_windows_envvars.c`);
  - ICDs a display adapter registers come first, and the loader dedupes by file name
    (`icd.c:66-78`). With Adrenalin's `amdocl64.dll` exposed, the driver's copy wins.

  `amdocl64.dll` links PAL statically and imports only system DLLs. AMD's ICD always
  reports one platform, `AMD Accelerated Parallel Processing`, even with no device
  (clr `cl_icd.cpp:119-134`). Measured on this host with TheRock's DLL and no gfx120X GPU
  enabled: 1 platform, 0 devices, under 1 s. The layout gate now also requires
  `bin\OpenCL.dll` and `bin\amdocl64.dll`.
- **Vulkan loader.** Server Core ships no `vulkan-1.dll`, so no Vulkan-linked binary
  could load in the image. The base image's Vulkan SDK cannot supply one: scoop installs it
  `copy_only=1`, its `Bin` has no loader, and `Helpers\VulkanRT.exe` is an installer that
  never runs. `windows/scripts/host/Install-VulkanLoader.ps1` therefore downloads LunarG's
  Runtime Components zip for `VULKAN_VERSION`:
  - pinned as `VULKAN_RT_WINDOWS_ZIP_SHA256`, which equals LunarG's published digest
    (`https://sdk.lunarg.com/sdk/sha/<v>/windows/<zip>.txt`); `bump_versions.py`
    `spec_vulkan` refreshes it with the version;
  - the signed x64 `vulkan-1.dll` goes into `C:\Windows\System32`, where `VulkanRT.exe`
    puts it on a real host. Its version must equal `VULKAN_VERSION`;
  - the verified copy and `VulkanRT-License.txt` go into `C:\vulkan-loader`
    (`VULKAN_LOADER_DIR`), which is not on PATH;
  - a System32 copy with other bytes is never overwritten: the build fails instead, so a
    base image that starts shipping its own loader is noticed.

  Why System32 and not a PATH directory: FFmpeg's Windows `dlopen` searches only the
  application directory and System32 (`compat/w32dlfcn.h` at n9.0.2), and Python 3.8+
  resolves a `.pyd`'s imports without PATH, which is how TVM's Vulkan runtime loads.
  System32 comes before PATH in the standard search, so the copy also wins over any PATH
  copy; an app-local copy still wins over it. The loader layer comes after the ROCm RUN in
  `Dockerfile.rocm`, so a Vulkan bump does not re-download the 2.3 GB tarball.
- **What the loader serves:** gstvulkan and amfcodec through it, llama.cpp's
  `ggml-vulkan.dll`, IREE's Vulkan HAL, OpenCV's vkcom backend, FFmpeg's `vulkan`
  hwdevice and TVM's Vulkan runtime. There is no Vulkan ICD in the container, so the
  loader reports zero devices there. That is the correct answer.
- **Smoke: `rocm-checks/GpuLoaders.ps1`.** It sorts before `GStreamer.ps1`. It requires
  that `vulkan-1.dll` resolves to System32's copy and is byte-identical to the pinned one
  beside its licence, exports `vkGetInstanceProcAddr` and `vkEnumerateInstanceVersion`, and
  is not older than the SDK's `VK_HEADER_VERSION`. It requires the Vendors value
  (`REG_DWORD 0`, an existing file), `amdocl64.dll` loading with its ICD exports, and
  `clGetPlatformIDs` returning 0 or -1001 with an AMD platform listed. Zero platforms is a
  finding, because AMD's ICD always reports its platform. Both loaders run in a child pwsh
  with a 120 s timeout; device counts are only logged.

Not proven yet: that PAL initialises cleanly in a GPU-less Server Core container (every
OpenCV T-API check in the image now loads it), and that the HKLM value survives into the
later layers. If PAL misbehaves, dropping the `Register-OpenClIcd` call is the quick
escape; `GpuLoaders.ps1` then reports the missing registration.

**Licences.** See [Redistribution](#redistribution) below.

**Not proven by anything here:** that HIP code runs. Windows containers get DirectX/DirectML
only, so a GPU check needs the bare host (Windows 11 25H2, with the RX 9070 XT re-enabled
outside any build window):
- `hipInfo`;
- the family's `-tests` tarball;
- a torch matmul compared against the CPU. This one is required, because upstream TheRock#8379
  reports torch+ROCm returning zeros on exactly that card.

## ONNX Runtime WebGPU EP (rocm lane, spike)

The rocm lane's chain ORT (built from source by `Build-OnnxFromSource.ps1`) is built **with
ORT's in-tree WebGPU execution provider**, over Dawn's D3D12 backend. It replaced the PyPI
`onnxruntime-ep-webgpu` 0.4.0 plugin the app venv carried for part of 2026-09-23: that
plugin was ORT code built by Microsoft, which the ORT single-source rule forbids
([`onnxruntime-single-source.md`](onnxruntime-single-source.md)).

**Gating.**
- It is a spike: on by default with `-Variant rocm`, off under `-NoRocmSpikes`.
- The driver sends `ORT_WEBGPU=1|0` plus the five `ORT_WEBGPU_WINDOWS_*` pins to
  `media-core-built-onnx` (`Get-BkRocmStageArg`). cpu and nvidia get none of them: the
  ARGs are valueless, and their configure line is unchanged.
- `ORT_WEBGPU=1` anywhere but the native rocm lane is a build error.
- `ORT_ENABLE_WEBGPU` is the unrelated Linux knob; the Windows spike does not read it.

**Why in-tree (`onnxruntime_USE_WEBGPU=ON`) and not the plugin build.**
- The in-tree EP registers inside `onnxruntime.dll`, so `get_available_providers()` lists
  `WebGpuExecutionProvider` in every interpreter and GenAI sees it with no extra call.
- The plugin build (`onnxruntime_USE_EP_API_ADAPTERS`) makes a separate provider DLL that
  each consumer must register with `register_execution_provider_library`, and GenAI
  would not see it without its own registration. The in-tree build needs none of that.
- ORT's `onnxruntime_CUSTOM_DAWN_SRC_PATH` takes a pinned, pre-patched Dawn tree and turns
  Dawn's own dependency fetch off.

**What is fetched, and how each fetch is pinned.** Nothing else is fetched. The configure
gate fails if Dawn's `fetch_dawn_dependencies` runs.

| Input | Source | Pin |
| --- | --- | --- |
| Dawn at the tag ORT's `cmake/deps.txt` names (`ORT_WEBGPU_WINDOWS_DAWN_VERSION`) | the GitHub tag archive | `ORT_WEBGPU_WINDOWS_DAWN_SHA256`, **and** a SHA1 equal to deps.txt's; the build refuses a deps.txt naming another tag |
| ORT's six Dawn patches | ORT's own tree, read from `onnxruntime_external_deps.cmake` in PATCH_COMMAND order | ORT's pin. Applied with GNU `patch --binary --ignore-whitespace -p1` (Git's `usr\bin\patch.exe`), because `git apply` rejects three of them |
| Dawn DEPS `jinja2`, `markupsafe`, `spirv-headers`, `spirv-tools` | as Dawn's `DEPS` names them | the commit read from DEPS; each checkout must equal it |
| DXC release (`ORT_WEBGPU_WINDOWS_DXC_VERSION`, `_ASSET`) | the DirectXShaderCompiler GitHub release | `ORT_WEBGPU_WINDOWS_DXC_SHA256`; uses the x64 `dxcompiler.dll`, `dxil.dll`, `dxcompiler.lib` and the three licence texts |

ORT's other `cmake/deps.txt` downloads are unchanged: ORT fetches them itself, SHA1-pinned
by ORT. Every rocm onnx build fetches these inputs again; there is no preseed yet.

**Why DXC is a pinned release, not built.** DXC's `WinIncludes.h` includes `<atlbase.h>`
under `_MSC_VER`, and the image has no ATL (the same C1083 the LLVM, IREE and TVM builds
record). Its clang-cl branch also adds `-Wall`, which is `-Weverything` there, and sets
`/Zi` in a way sccache cannot cache. So `Invoke-DawnPrebuiltDxcPatch` replaces Dawn's
`AddSubdirectoryDXC()` with an imported `dxcompiler` target over the pinned release.
`DAWN_USE_BUILT_DXC` stays ON, so Dawn keeps DXC (ShaderF16, subgroups) instead of falling
back to FXC. The patch refuses to run if that block moves.

**Dawn and Tint under clang-cl.** Both have upstream clang-cl branches, `DAWN_WERROR` is off
by default, and no flags or patches are added. That is read from source; the first
container build is the proof.

**What ships.**
- `<ort>\bin\dxcompiler.dll` and `dxil.dll`, beside `onnxruntime.dll`, which loads them at
  run time. The build refuses an `onnxruntime.dll` that imports them.
- The same pair in the chain wheel's `onnxruntime\capi\`, checked byte for byte.
- `<ort>\ROCM-FEATURES.txt`, the marker: `ORT_WEBGPU=0|1` and, when on, `DAWN_VERSION`,
  `DXC_VERSION`, `DXCOMPILER_SHA256` and `DXIL_SHA256`.

**Licences.** Dawn and Tint are linked statically into `onnxruntime.dll` and
`onnxruntime_pybind11_state.pyd`; their BSD 3-Clause text is already ORT's own `dawn`
entry in `ThirdPartyNotices.txt`. ORT's notices do not cover DXC, so the build copies
DXC's three texts to `<ort>\licenses\directx-shader-compiler\` and appends them to the
wheel's `onnxruntime\ThirdPartyNotices.txt` (`Add-OrtWebGpuWheelNotice`) before
`bdist_wheel`. Both are `docs/deps/deps.json` rows, which `Rocm.OrtWebGpu.Tests.ps1`
requires.

**Build gates.**
- After configure, `Get-OrtWebGpuConfigureFinding` requires `onnxruntime_USE_WEBGPU=ON`,
  `DAWN_FETCH_DEPENDENCIES=OFF`, `DAWN_USE_BUILT_DXC=ON`, D3D12 on, Vulkan off and the
  prebuilt-DXC log line, and throws otherwise.
- After the wheel, `Get-OrtWebGpuWheelFinding` requires `WebGpuExecutionProvider` in the
  installed wheel, the literal `dxcompiler.dll`/`dxil.dll` pair in capi equal to the
  staged hashes, and the DXC notice entry.

**Smoke (`rocm-checks\OrtWebGpu.ps1`, GPU-less).** It reads the marker and fails on a mode
that does not match `EXPECT_ROCM_SPIKES` (a stale parent) or a DLL hash that does not
match. With the spike off it requires no DXC leftovers. With it on, in the base `python`
and in the app venv, it checks that:
- `WebGpuExecutionProvider` is listed;
- an identity-model session gets the WebGPU EP, or fails **only** with
  `Failed to get a WebGPU adapter`;
- `onnxruntime_genai` loads that same `capi\onnxruntime.dll` and creates a WebGPU model, or
  fails for want of an adapter;
- `dxil.dll` then `dxcompiler.dll` load from capi and export `DxcCreateInstance`.

Any other outcome fails. The whole-script test runs it against a real venv and a shim
`python`, and each finding carries its `[base]` or `[venv]` label.

**Not proven yet:** Dawn and Tint compiling under the image's clang-cl; Dawn finding the
Windows SDK's `d3dcompiler_47.dll` in the container; the build time the onnx stage gains
(probably large); and what Server Core answers without a GPU. If it fails before adapter
selection, the error text differs and the smoke goes red, by design.

**Bumping.** The Dawn pin follows `ONNXRUNTIME_VERSION`: when ORT moves, take the tag from
its `cmake/deps.txt` `dawn` row and re-measure the archive's SHA256 (held with `bump:hold`).
DXC is a report row: `bump_versions.py` (`spec_ort_webgpu_dxc`) proposes the newest release
and, with `--write`, its single `dxc_YYYY_MM_DD.zip` name and SHA256.

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
- **Loading amfcodec on an image without the Vulkan loader.** amfcodec links `gstvulkan`, so the same skip applies there. The rocm image ships `vulkan-1.dll` in System32 (§ The ROCm layer), so amfcodec IS load-probed on it. At 1.29.2 its Windows `plugin_init` is D3D11-only and returns TRUE without `amfrt64.dll`, and gstvulkan registers its elements even when `vkCreateInstance` fails for want of an ICD. On the rocm image a missing loader is a `GpuLoaders.ps1` finding.

Elements have to be proven on the bare host with the RX 9070 XT: `gst-inspect-1.0 hipconvert`, `amfh265enc`, `d3d12h265dec`. Never bake a GPU-less GStreamer registry into an image: these plugins call no `gst_plugin_add_dependency`.

Not at 1.29.2: `onnxinference` `execution-provider=hip`/`migraphx`/`dml`. They exist only on GStreamer `main` (Aug–Sep 2026, untagged).

Evidence: `subprojects/gst-plugins-bad/{meson.options,gst-libs/gst/hip/{meson.build,gsthiploader.cpp,gsthiprtc.cpp,gsthip-interop.cpp},sys/hip/{meson.build,plugin.cpp},sys/amfcodec/{meson.build,plugin.cpp,gstamfencoder.cpp},gst-libs/gst/d3d1{1,2}/meson.build,sys/d3d1{1,2}/meson.build}` at tag `1.29.2`; the TheRock 10.0.0 tarball listing; the CPU build log's install lines and import-walk summary.

## FFmpeg on the rocm lane: AMD AMF and Vulkan

AMF is below; Vulkan has its own subsection, [§ Vulkan](#vulkan-rocm-lane-only-since-2026-09-23).

**What AMF enables (rocm lane only).**
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

**Smoke check.** `windows/scripts/build/rocm-checks/FFmpeg.ps1`, run by `Test-RocmImage.ps1` under `EXPECT_ROCM=1`. It checks that the image's ffmpeg lists every AMF encoder, decoder, filter and the `amf` hwaccel, and that `--enable-amf` appears in its configuration line. It also checks that the AMF headers are installed and that no `amfrt*.dll` ships in the image. Since 2026-09-23 it checks the Vulkan components too (§ Vulkan below). Listing reads FFmpeg's static tables, so no GPU is needed. It does NOT prove that an AMF session opens.

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

### Vulkan (rocm lane only, since 2026-09-23)

**What it enables.** `--enable-vulkan`, built against the base image's Vulkan SDK (`VULKAN_VERSION`, headers at `VK_HEADER_VERSION` 357):
- the `vulkan` hwdevice, with `hwupload`/`hwmap`/`hwdownload` to and from it;
- Vulkan Video decode hwaccels `av1`, `h264`, `hevc`, `vp9`, and compute-shader decode hwaccels `apv`, `dpx`, `ffv1`, `prores`, `prores_raw`;
- encoders `h264_vulkan`, `hevc_vulkan`, `av1_vulkan` (Vulkan Video) and `ffv1_vulkan`, `prores_ks_vulkan` (compute);
- 18 filters: `avgblur`, `blackdetect`, `blend`, `bwdif`, `chromaber`, `flip`, `gblur`, `hflip`, `interlace`, `nlmeans`, `overlay`, `scale`, `scdet`, `transpose`, `v360`, `vflip`, `xfade` (each `_vulkan`), plus the source `color_vulkan`;
- swscale's Vulkan/SPIR-V backend (`libswscale/vulkan`).

`vp9_vulkan` and `av1_vulkan` also need `vulkan_1_4`, that is headers >= 1.4.317 (configure:3547, 3625, 7849). None of it uses ROCm; like AMF it is on this lane by owner decision. The cpu and nvidia configure lines are byte-identical to before, which `SourceBuild.FfmpegRocm.Tests.ps1` asserts.

**Why it was off.** The SDK ships no `vulkan.pc`, so `check_pkg_config_header_only` fails. The fallback `check_cpp_condition` (configure:7806) sees only CFLAGS, and n9.0.2 never assigns `$vulkan_incflags`. The SDK's `Include` missing from INCLUDE was not the cause.

**How.**
- `Get-FfmpegVulkanPlan` exists only when the AMF plan does, so `HasRocm` is still read in one place. It fails closed when `VULKAN_SDK` is unset or contains whitespace (configure runs the glslc probe unquoted), or when `Include\vulkan\vulkan.h`, `Include\spirv-headers\spirv.h` or `Bin\glslc.exe` is missing.
- configure gets `--enable-vulkan --extra-cflags=-I<VULKAN_SDK>/Include --glslc=<VULKAN_SDK>/Bin/glslc.exe`. `--glslc` pins the SDK's compiler; otherwise configure takes the first `glslc`, `glslang` or `glslangValidator` on PATH.
- SPIR-V is compiled at build time; n9.0.2 has no libshaderc or libglslang option. make runs glslc over the 58 `*.comp.glsl` shaders, and FFmpeg's own `bin2c` embeds the result in the libraries (`ffbuild/common.mak:113-133`). No shader compiler ships.
- Shader compression follows zlib+gzip autodetection (configure:7275-7285). Which path the image takes is not measured yet; the build logs `config.mak: shader compression ON|OFF` right after the Vulkan gate.
- **Build gate.** `Get-FfmpegVulkanConfigGap` fails the stage unless `ffbuild/config.mak` enables all 35 symbols (`CONFIG_VULKAN`, `CONFIG_VULKAN_1_4`, `HAVE_SPIRV_HEADERS_SPIRV_H`, 9 hwaccels, 5 encoders, 18 filters) and `GLSLC=` is the plan's glslc. `spirv_compiler` is in no configure list, so the components glslc builds stand in for it.
- **No new pin.** The headers and glslc come from the SDK that `VULKAN_VERSION` already pins, so a `VULKAN_VERSION` bump now also recompiles the rocm FFmpeg.

**Run time.** FFmpeg never links `vulkan-1.dll`; it dlopens it (`libavutil/hwcontext_vulkan.c` `load_libvulkan`), and its Windows `dlopen` searches only the application directory and System32. In the rocm image that finds the sdk layer's System32 copy (§ The ROCm layer); with no Vulkan ICD in a container, device creation then fails. On a bare host it loads the driver's loader.

**Smoke check** (`rocm-checks/FFmpeg.ps1`, no GPU). It requires that `-encoders`, `-filters` and `-hwaccels` list the 5 encoders, the 18 filters and `vulkan`; that `ffmpeg -h decoder=X` lists `vulkan` under "Supported hardware devices" for each of the 9 hwaccel decoders; that the configuration line has `--enable-vulkan`; and that no DLL or EXE in the FFmpeg bin imports `vulkan-1.dll`, statically or delay-loaded. An `avutil-<major>.dll` must be among the files read (hwcontext_vulkan lives there), so the import check cannot pass empty. It does NOT prove that a Vulkan device opens.

**Unchanged by it.** A generic encoder lookup by codec id still resolves to `h264_amf`, `hevc_amf` and `av1_d3d12va`: the Vulkan encoders register after `*_d3d12va` and `*_amf` (allcodecs.c:861, 876, 891). `vulkan` is in no GPL, nonfree or version3 list (configure:2029-2070, 2192), so the licence stays `--enable-gpl --enable-version3`. The Vulkan-Headers are `Apache-2.0 OR MIT`, the SPIRV-Headers MIT, and glslc is a build-time tool only.

**Not enabled: libplacebo.** FFmpeg's `libplacebo` filter needs libplacebo >= 7.351.0 through pkg-config (configure:7425). That would be a new meson source build with its own submodules to pin, plus a shader-compiler library shipped beside FFmpeg. `scale_vulkan` and the other Vulkan filters already cover GPU scaling.

**Limits.**
- The image has not built this yet. The host evidence is object files only: a real n9.0.2 configure with Strawberry mingw gcc 13.2 and the same SDK version enabled all 35 symbols, and all 103 Vulkan targets (45 C objects, 58 shaders) compiled. No DLL was linked, and that configure took gcc's path, not `--toolchain=msvc`. The first `-Variant rocm` media build is the first clang-cl compile.
- No GPU-less check can show that a device opens or a shader runs. AMD's Windows Vulkan Video is reported buggy upstream (AMD-Gfx-Drivers#99; not re-checked). Verify on the bare host with the exported `C:\runtime\ffmpeg`, for example `ffmpeg -init_hw_device vulkan=vk:0 -filter_hw_device vk -f lavfi -i testsrc2 -vf format=nv12,hwupload,scale_vulkan=w=1280:h=720,hwdownload,format=nv12 -f null -`.

Evidence (n9.0.2): `configure` 370, 405, 1114-1131, 3192-3677, 4149-4308, 7275-7287, 7800-7861; `libavutil/hwcontext_vulkan.c` 650-685; `compat/w32dlfcn.h`; `ffbuild/common.mak` 113-133; the `vulkan/Makefile`s under `libavcodec`, `libavfilter` and `libswscale`; `fftools/opt_common.c` 355-366.

## OpenCV on the rocm lane

**What the rocm lane adds: nothing new at build time. The AMD path was already there.** OpenCV 5.0.0 has no HIP or ROCm code path. Its GPU paths that work on AMD hardware are all vendor-neutral, and every lane already compiles them:

- **OpenCL T-API:** `WITH_OPENCL=ON`, `WITH_OPENCL_SVM=ON`.
- **D3D11 interop:** `WITH_DIRECTX=ON`.
- **Vulkan backend of the classic dnn engine:** `WITH_VULKAN=ON`.

OpenCL builds against OpenCV's bundled `3rdparty/include/opencl/1.2` headers with no import library. At run time it loads `OpenCL.dll` by bare name through the standard DLL search and requires `clEnqueueReadBufferRect`. The rocm layer supplies a Khronos ICD loader, `C:\TheRock\build\bin\OpenCL.dll`, last on PATH, plus AMD's PAL-based `amdocl64.dll`, which `Install-Rocm.ps1` registers as an ICD (§ The ROCm layer). That is what gives the T-API a runtime on this lane. Until 2026-09-23 nothing registered the ICD, so the loader found no platform.

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

  `cv2.ocl.haveOpenCL()` is reported warn-only, because the smoke container has no GPU. With the ICD registered it should print True, listing AMD's platform with no device; that is unverified in the image.

**Not rocm-specific, but new on 2026-09-23:** on every Windows lane OpenCV stopped downloading its own ORT zip, links the chain's, and ships a working G-API DirectML EP. That change is owned by the ORT page ([`onnxruntime-single-source.md`](onnxruntime-single-source.md)).

**Choosing the device.** The host exposes a dGPU and an iGPU, so select one with `OPENCV_OPENCL_DEVICE=<platform>:<type>:<name>`, for example `:GPU:gfx1201`. `OPENCV_OPENCL_RUNTIME=<path>` pins a specific loader.

**Not available, and why:**

- **HIP for `cv::cuda`/`cudev` and HIP-in-UMat.** Only unmerged upstream PRs exist, validated on Linux only: opencv#29285/#29527 with contrib #4147/#4178, and opencv#29372.
- **MIGraphX dnn backend** (opencv#29726). It is `NOT UNIX`-guarded, and no Windows MIGraphX exists.
- **RPP HAL** (opencv#29505). Closed unmerged.
- **GPU inside the container.** Microsoft supports only DirectX in Windows containers, and on this host the 26100/26200 build skew blocks GPU passthrough. Measure the OpenCL T-API on the bare host or on a 26100 host. See [windows-build-resources.md](windows-build-resources.md).

Upstream references, all at the 5.0.0 tag: `cmake/OpenCVDetectOpenCL.cmake`, `modules/core/src/opencl/runtime/opencl_core.cpp`, `CMakeLists.txt:333-344`, and TheRock's `win-tarball-list` (`bin/OpenCL.dll`, `bin/amdocl64.dll`; no `clAmd*`).

## IREE and TVM on the rocm lane

The ROCm layer (`Dockerfile.rocm`) sits in the sdk slot, so `media-tvm` sees `GPU_TYPE=rocm` and TheRock at `C:\TheRock\build`. What that turns on:

| Component | rocm lane | cpu / nvidia |
| --- | --- | --- |
| IREE runtime | HIP HAL driver (`-DIREE_HAL_DRIVER_HIP=ON`, `-DIREE_ROCM_TEST_TARGET_CHIP=` so the rocminfo probe is skipped) | unchanged |
| IREE compiler | `rocm` target (`-DIREE_TARGET_BACKEND_ROCM=ON`: AMDGPU in IREE's in-tree LLVM, linked by `iree-lld`) | unchanged |
| TVM runtime | `USE_OPENCL=ON` (TVM's lazy `OpenCL.dll` loader, no SDK) | `USE_OPENCL=OFF` |
| TVM ROCm spike (`TVM_ROCM=1`; `-NoRocmSpikes` passes 0) | AMDGPU in a minimal LLVM that TVM builds for itself (`X86;AArch64;NVPTX;AMDGPU`; the toolchain LLVM on PATH has no AMDGPU), `USE_ROCM=C:/TheRock/build`, `tvm_runtime_rocm.dll` on HIP | off |

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

**Which LLVM TVM links.** Every amd64 lane puts the toolchain's patched LLVM (`C:\llvm-patched`) first on PATH. It is built with `LLVM_TARGETS_TO_BUILD=AArch64;X86` (`Build-LlvmFromSource.ps1`), so it has no AMDGPU. cpu, nvidia and the rocm lane without the spike link it unchanged, and never query it.

On the spike, `Build-TvmFromSource.ps1` (`Get-TvmLlvmChoice`) asks the PATH `llvm-config --targets-built`. When AMDGPU is missing, that llvm-config counts as absent, and TVM builds its own minimal LLVM with `X86;AArch64;NVPTX;AMDGPU`. It uses the same pinned `LLVM_WINDOWS_VERSION` source tarball, goes through sccache, and installs to `C:\temp\llvm-dev\install`. That directory is not shipped: the merge copies only `C:\runtime\lib\tvm`. Adding AMDGPU to the toolchain LLVM instead would re-key every lane.

After the choice, the build reads `--targets-built` back from the llvm-config TVM will link, and the spike throws when AMDGPU is missing. `ROCM-FEATURES.txt` records that read-back list as `LLVM_TARGETS`, not the requested one, so the rocm lane without the spike records `AArch64;X86`.

Until 2026-09-23 the minimal-LLVM branch ran only when PATH had no llvm-config. On amd64 the spike therefore always found the patched LLVM, threw at the AMDGPU check before configure, and took the whole media-tvm RUN, IREE included, down with it. The minimal LLVM with AMDGPU has not been built in the image yet; its cost and memory use are unmeasured.

`llvm-config` must never resolve into the ROCm tree.

**Compile only, no GPU.** A Windows container gets no HIP compute, so both gates compile and list:

- The build gates check that `iree-compile` targets hip gfx1201, that `--list_drivers` shows `hip`, and that `import tvm` loads the OpenCL and ROCm sidecars.
- The smoke checks `windows/scripts/build/rocm-checks/IREE.ps1` and `TVM.ps1` re-check the image. They assert a linked ELF64 AMDGPU code object with `EF_AMDGPU_MACH` 0x4E (gfx1201) from IREE (CLI and python) and from TVM's own AMDGPU codegen. They read `C:\runtime\lib\tvm\ROCM-FEATURES.txt` to know whether the spike ran.
- `TVM.ps1` also requires AMDGPU in the marker's `LLVM_TARGETS` when `TVM_ROCM=1`. It compares `LLVM_TARGETS` both ways with what the runtime probe reads from `target.llvm_get_targets` (null when tvm_compiler has no LLVM). TVM names targets by `llvm::Triple::getArchTypeName`: X86 → `x86_64`, AArch64 → `aarch64`, NVPTX → `nvptx64`, AMDGPU → `amdgpu` at LLVM 23 (`amdgcn` before the rename, also accepted). A marker that claims a target the compiler lacks, or omits one it links, is a finding.
- The unit suite runs `TVM.ps1` end to end against a fake python and the build's own marker writer, so dropping either LLVM check, or recording the requested list instead of the read-back one, fails a test.

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

The rocm image's app venv (`C:\opt\OrchestrANT\.venv`) runs **AMD's PyTorch for Windows ROCm**. It has torch 2.13.0+rocm10.0.0 and torchvision 0.28.0+rocm10.0.0 (cp314, win_amd64), the `rocm[libraries]` 10.0.0 runtime, and the device wheels for both GPUs of the pinned gfx120X-all family: gfx1201 (RX 9070 series) and gfx1200 (RX 9060 series). It also gets `ai-edge-litert` (§ The LiteRT extra, below). The cpu and nvidia images are unchanged.

WebGPU for ONNX Runtime comes from the chain ORT itself ([§ ONNX Runtime WebGPU EP](#onnx-runtime-webgpu-ep-rocm-lane-spike)). The PyPI plugin `onnxruntime-ep-webgpu` that this venv carried for part of 2026-09-23 is gone, with its `TORCH_ROCM_WINDOWS_ORT_EP_WEBGPU_*` pins: it was ORT code not built by this chain.

**How it is selected.** `windows/Dockerfile.torch` declares a global `ARG TORCH_ROCM=0` and ends with `FROM rocm-${TORCH_ROCM}`:

- `app` is the old single stage, unchanged: `uv sync` with `PYTORCH_EXTRA=pytorch-cpu`, so the app lock resolves the same way on every lane.
- `rocm-0` is `app` with no instruction of its own. This is what cpu and nvidia build, with the same cache key and layers as before.
- `rocm-1` is built only when the driver passes `TORCH_ROCM=1`. That happens on the rocm lane only (`Get-BkRocmStageArg`).

`rocm-1` runs `windows/scripts/build/Install-TorchRocm.ps1`, then `Build-TorchApp.ps1 -Mode verify`, so the app's own smoke suite runs on the ROCm torch. That verify runs the ORT census first: any ONNX Runtime distribution that is not a chain wheel fails the stage ([`failure-modes.md`](failure-modes.md#the-torch-stage-fails-with-ort-census-fail)). The installer itself also requires the venv's onnxruntime RECORD digest to be the same before and after it runs (`Assert-TorchRocmOrtUnchanged`).

**What the installer does.**

- **Pins.** Fourteen files are pinned by URL + SHA256 in `versions.env` (`TORCH_ROCM_WINDOWS_<NAME>_URL` / `_SHA256`, next to `ROCM_WINDOWS_*`): 13 from AMD, and `ai-edge-litert` from PyPI. They reach the stage as ARG defaults that `sync_versions.py` keeps in step. AMD publishes no hashes and its index carries no `#sha256=` fragments, so every SHA256 is self-measured (`curl -fL <url> | sha256sum`). The URLs are AMD's final addresses (`stable.repo.amd.com/rocm/pytorch/whl-next/…`, `/rocm/core/whl-next/…`).
- **Coupling, checked at build time.** Every file except `rocm-bootstrap` must be built for `ROCM_WINDOWS_RELEASE`. The device wheels must name one GPU and match their package's version. The venv must be `cp314`. The app lock's torch/torchvision must be the same release as the pins, so an `APP_REF` that moves torch fails the stage until the pins move too. **Bump the whole `TORCH_ROCM_WINDOWS_*` block with `ROCM_WINDOWS_RELEASE`.**
- **One device-wheel set per GPU.** `TORCH_ROCM_WINDOWS_SDK_DEVICE[_<GFX>]` names the GPU, and `TORCH_DEVICE`/`TORCHVISION_DEVICE` with the same suffix must be that GPU's wheels at torch/torchvision's exact version (`Get-TorchRocmGpuTarget`). The unsuffixed set is gfx1201; gfx1200 uses `_GFX1200`. The one family wheel `amd-torch-device-gfx12-0` must serve every pinned GPU. The gfx1200 and gfx1201 sets share only an empty `_rocm_sdk_libraries/__init__.py`.
- **rocBLAS coverage.** Before any download, every GPU the image's rocBLAS ships kernels for (`%HIP_PATH%\bin\rocblas\library\TensileLibrary_lazy_<gfx>.dat`, the files `rocm-checks\LlamaCpp.ps1` reads too) must have device pins (`Assert-TorchRocmGpuCoverage`). Pinning more GPUs is allowed. A `ROCM_WINDOWS_GFX_FAMILY` change therefore fails the torch stage until the device pins follow.
- **Offline install.** Files are cached by hash on the torch stage's uv cache mount (`C:\uvcache\torch-rocm\<sha256>\<file>`, about 2 GB) and re-hashed before reuse. The install is `uv pip install --force-reinstall --no-deps --no-index --no-build-isolation --require-hashes`. No index is contacted and nothing is resolved. The `rocm` sdist builds on the venv's setuptools (83.0.0 from the app lock).
- **The no-GPU trap.** The `rocm` sdist's `setup.py` calls `offload-arch` to choose a GPU family. The build container has no GPU (TheRock's `offload-arch.exe` sits in `lib\llvm\bin`, which stays off PATH). The installer sets `ROCM_SDK_TARGET_FAMILY` to the first pinned GPU, gfx1201. That variable takes exactly one GPU, but it only fills the sdist's generic `device` extra, and `--no-deps` never reads it; the pinned per-GPU wheels stand in for AMD's per-GPU extras (`rocm[device-gfx1200]`, `rocm[device-gfx1201]`, `device-all`). `ROCM_BOOTSTRAP_DISABLE_DETECTION=1` is also set; `rocm-bootstrap` 0.1.0 detects only inside its installer plugin, which `--no-deps` never runs.
- **Dependency confusion.** PyPI has an unrelated `rocm` 0.1.0 and `rocm-bootstrap` 0.3.0. Pinning by URL + hash rules both out.

**Smoke.** `windows/scripts/build/rocm-checks/Torch.ps1` runs under `Test-RocmImage.ps1` (`EXPECT_ROCM=1`) and at the end of the install. It imports torch/torchvision/rocm_sdk without a GPU and asserts:

- `+rocm<release>` builds of torch and torchvision
- a non-empty `torch.version.hip`
- `torch.version.rocm` and `rocm_sdk` equal to the release
- the runtime and device packages at matching versions
- `rocm-sdk-device-`, `amd-torch-device-` and `amd-torchvision-device-<gfx>` for every GPU rocBLAS serves (gfx1200 and gfx1201)
- the chain onnxruntime still imports and lists `DmlExecutionProvider`
- `ai_edge_litert.interpreter` imports, and `libLiteRtWebGpuAccelerator.dll` loads with `LiteRtAcceleratorImpl` resolved
- every unconditional requirement of `ai-edge-litert` is installed; on the host, the import alone did not catch a missing `ml_dtypes`

It never calls `torch.cuda`, and `torch.cuda.is_available()` is False in the container by design.

### The LiteRT extra

`ai-edge-litert` 2.2.0 (`TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_*`, pinned by PyPI URL and PyPI's SHA256) goes into the rocm venv through the same offline, hash-pinned, `--no-deps` install. It is LiteRT's Python package with its prebuilt WebGPU accelerator `libLiteRtWebGpuAccelerator.dll` (Dawn statically linked), so it works on any vendor's D3D12 GPU; it is on the rocm lane by owner decision.
- It is the newest release with a cp314 win_amd64 wheel. The app lock records 2.1.6, but the app's pyproject leaves it unpinned.
- The app's `uv sync` still excludes it on every lane (`--no-install-package`), so cpu and nvidia are unchanged.
- Its requirements are already in the venv: the lock's own ai-edge-litert dependencies, plus `ml_dtypes`, which `Build-TorchApp.ps1` copies in from the base interpreter.
- Its Dawn falls back to FXC when DXC is absent. Whether Dawn accepts the WARP adapter a container can see is unverified.

**Limits.**

- GPU compute is not proven by the image. The bare-host check (torch matmul on the GPU vs CPU, above) still applies. The upstream TheRock#8379, open, reports zeros from torch on RX 9070 XT with ROCm 7.14.
- There is no Windows triton wheel, so GPU `torch.compile`/inductor is unavailable.
- The wheels carry their own ROCm 10.0.0 runtime (`_rocm_sdk_core`/`_rocm_sdk_libraries` in the venv, about 4 GB installed). It is the same release as `C:\TheRock\build`, but it is a second copy.
- The CPU torch installed by `uv sync` stays as dead bytes in the `app` layer, about 0.5 GB. That is the cost of leaving the cpu/nvidia stage untouched.
- The rocm lane runs the app verify twice (CPU torch, then ROCm torch), about 1–2 minutes extra.
- gfx1200 adds about 430 MB of downloads (the rocm-sdk device wheel alone is 377,648,520 B) and about 0.7 GB installed.
- `whl-next` is AMD's only Windows channel. A withdrawn file fails the download loudly; a cached copy keeps working.

**Evidence** (2026-09-23, Windows 11 host, CPython 3.14.7, uv 0.12.7):

- All ten original files downloaded and hashed; sizes match `Content-Length`. The torch wheel is 113,446,960 bytes; rocm-sdk-core is 758,050,981.
- The gfx1200 wheels were hashed by streaming, sizes equal to `Content-Length` (51,106,952, 131,254 and 377,648,520 B). AMD's `rocm-10.0.0` sdist declares the per-GPU extras (`setup.py`, `src/rocm_sdk/_dist_info.py`).
- The offline install replaced a CPU torch/torchvision in 59 s with the rocm-check clean.
- `import torch` reports `2.13.0+rocm10.0.0 hip 7.15.26333 rocm 10.0.0`.
- The app smoke's CPU ops pass with `HIP_VISIBLE_DEVICES=-1` (0 devices).
- `amdhip64_7.dll` statically imports only system DLLs plus `amd_comgr`/`rocm_kpack`. The driver is loaded at run time, which is why `import torch` needs no GPU.

Tests: `windows/scripts/tests/Torch.Rocm.Tests.ps1`.

## llama.cpp HIP and Vulkan (`Dockerfile.rocm-llama`, rocm lane only)

The stage installs two official builds of the same llama.cpp release, each in its own
directory: the HIP build here, and the Vulkan build in
[§ The Vulkan build](#the-vulkan-build-cruntimeoptllamacpp-vulkan).

**What it adds.** The rocm image carries llama.cpp's official Windows ROCm/HIP release. The pinned build is b11115, asset `llama-b11115-bin-win-rocm-10.0-x64.zip`. It lives in `C:\runtime\opt\llama.cpp-hip`, which `LLAMA_CPP_HIP_HOME` names. It contains:
- `llama-server.exe`, `llama.exe` and the other tools;
- the CPU `ggml-cpu-*.dll` variants;
- `ggml-hip.dll`, 973 MB, with device code for 20 GPUs from gfx1010 to gfx1201.

Upstream builds this zip against the same TheRock 10.0.0 release the rocm sdk installs (release.yml `windows-rocm` job, pip `rocm[libraries,devel]==10.0.0`). Nothing is compiled here, so AMD's clang is not involved.

**Where it sits.** base → sdk (rocm) → toolchain → media → [migraphx] → **llama** → torch → final. The stage is `Dockerfile.rocm-llama`, target `built`; its five `LLAMA_CPP_*` pins are forwarded by `Build-Buildkit.ps1`. `-NoRocmSpikes` builds it directly on the merged media.

**How it is installed** (`windows/scripts/build/Install-LlamaCpp.ps1 -Backend hip`). One installer serves both builds; a backend table (`Get-LlamaCppBackendSpec`) holds what differs. For HIP it fails closed:
- It runs only when `Get-GpuEnvironment` reports `HasRocm`, and only when ROCm's bin has `amdhip64_7.dll`, `hipblas.dll` and `rocblas.dll`.
- The asset's build number must equal `LLAMA_CPP_HIP_BUILD`, and its `rocm-X.Y` must equal `ROCM_WINDOWS_RELEASE`'s major.minor.
- The zip is verified against `LLAMA_CPP_HIP_SHA256`.
- The zip must be flat, must hold the load-bearing files, and may shadow no ROCm DLL except the HIP runtime.

The script then writes `llama-cpp-hip-manifest.json` (size and SHA256 of every file). The same RUN then runs `rocm-checks\LlamaCpp.ps1 -Backend hip`, so a bad pin fails this stage.

**Which DLLs load from where.**
- **HIP runtime, from the llama directory.** `amdhip64_7.dll`, `rocm_kpack.dll` and `amd_comgr.dll` sit next to the exes. This is upstream's workaround: the Adrenalin driver's System32 `amdhip64_7.dll` otherwise wins the loader search (llama.cpp#26929).
- **Math libraries, from ROCm's bin.** hipBLAS, rocBLAS, hipBLASLt and their kernel directories load from `C:\TheRock\build\bin`, which is last on PATH.
- **Never on PATH.** The llama directory stays off PATH, because its HIP runtime would otherwise shadow ROCm's for every process.

Measured 2026-09-23:
- The three bundled DLLs are the same bytes as TheRock 10.0.0 gfx120X-all's (amdhip64_7 SHA256 `546fb3d6…`, rocm_kpack `97b59ca4…`, amd_comgr same size and CRC32).
- ggml-hip.dll imports 10 hipBLAS and 50 HIP functions, and TheRock's DLLs export all of them.

So one HIP runtime serves the whole process, and there is no version skew.

**What the smoke check proves** (`windows/scripts/build/rocm-checks/LlamaCpp.ps1`). Run with no arguments, as the smoke gate runs it, it grades both builds. For HIP it runs with no GPU:
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
- **Pinning.** Upstream publishes several builds a day, all flagged prerelease. Renovate reports new builds (approval-gated). `python docs/scripts/bump_versions.py --write-all` moves the build to the newest one that publishes both a win-rocm and a win-vulkan zip, together with the ROCm asset name and both SHA256s. The stable release v0.4.1 names build b10964, which also has a win-rocm-10.0 zip.

**Evidence.**
- https://github.com/ggml-org/llama.cpp/releases/tag/b11115
- https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/.github/workflows/release.yml (`windows-rocm` job, lines 978-1136)
- https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/.github/actions/windows-setup-rocm/action.yml
- https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/common/arg.cpp (`--version` handler) and tools/server/server.cpp (`llama_server` start-up order)
- https://github.com/ggml-org/llama.cpp/issues/26929

### The Vulkan build (`C:\runtime\opt\llama.cpp-vulkan`)

**What it adds.** llama.cpp's official Windows Vulkan zip of the same build, b11115: asset `llama-b11115-bin-win-vulkan-x64.zip`, 31,973,078 B. It lives in its own directory, which `LLAMA_CPP_VULKAN_HOME` names, and it is never on PATH. It is the vendor-neutral path to an AMD GPU, and the only one for GPUs the gfx120X-all rocBLAS has no kernels for, such as the gfx1036 iGPU.
- Upstream builds only `ggml-vulkan.dll` (`-DGGML_VULKAN=ON -DGGML_CPU=OFF -DGGML_BACKEND_DL=ON`, Vulkan SDK 1.4.357.0) and then adds the windows-cpu zip's tools.
- Measured 2026-09-23: all 51 files the Vulkan zip shares with the HIP zip are byte-identical (CRC32 and size). The zips differ only in `ggml-vulkan.dll` against `ggml-hip.dll` plus the three HIP runtime DLLs.

**Pins.** Only `LLAMA_CPP_VULKAN_SHA256` is new. The build stays one pin, `LLAMA_CPP_HIP_BUILD`, the asset name follows from it, and the LICENSE pin is the HIP build's, because it is the same tag's LICENSE. The ARG is declared after the HIP RUN, so a Vulkan bump keeps the 256 MB HIP layer cached.

**How it is installed:** `Install-LlamaCpp.ps1 -Backend vulkan`, in its own RUN, which then runs `rocm-checks\LlamaCpp.ps1 -Backend vulkan`. It fails closed: rocm lane only; the zip verified against its SHA256 and flat; `ggml-vulkan.dll`, `ggml-base.dll`, `ggml.dll`, `llama.dll` and `llama-server.exe` present; no bundled `vulkan-1.dll` (the loader comes from the image) and no ROCm DLL; the LICENSE fetched at the tag; `llama-cpp-vulkan-manifest.json` written last.

**The Vulkan loader.** `ggml-vulkan.dll` statically imports `vulkan-1.dll` (for `vkGetInstanceProcAddr`, `vkGetDeviceProcAddr`, `vkGetPhysicalDeviceFeatures2` and `vkCmdCopyBuffer`). In the image that is the sdk layer's System32 copy (§ The ROCm layer); on a bare host it is Adrenalin's. The check accepts a loader from System32 or from a PATH entry, and refuses one in the llama directory or the Windows directory.

**What the smoke check proves,** with no GPU:
- the shipped bytes equal the manifest; a file that cannot be read is a finding;
- the directory is not on PATH;
- a child pwsh loads `ggml-vulkan.dll` and resolves `ggml_backend_init`, with `ggml-base.dll` from the llama directory and `vulkan-1.dll` from where the loader order says;
- `vkEnumerateInstanceVersion`, which the loader answers without an instance, driver or GPU, reports API 1.2 or later. `ggml_vk_instance_init` refuses anything lower (ggml-vulkan.cpp@b11115:4969-4973);
- `llama-server --version` reports the pinned build.

It never calls `ggml_backend_init`, because that creates a VkInstance. `--list-devices` is no probe: release builds load backends silently, and `ggml_backend_vk_reg` returns NULL on any Vulkan error, so a missing loader and a missing GPU both print "(none)".

**Why a separate directory.** Each directory is one upstream zip, verified file by file. `ggml-vulkan.dll` beside `ggml-hip.dll` would load, but `ggml_backend_load_all` loads HIP first and llama.cpp then skips a second device with the same `device_id`, so on the RX 9070 XT Vulkan would only add the iGPU. ggml also searches the current directory for backends, so do not run one build with the other's directory as CWD.

**Limits.**
- No GPU in the container: `ggml-vulkan` registers no device there. On the bare host it uses Adrenalin's Vulkan ICD. Nothing proves a kernel runs.
- Size: about +91 MB and +1 layer.
- **Windows Defender** flagged `llama-gguf-split.exe` (byte-identical in both zips) as `Trojan:Win32/Wacatac.B!ml`, an ML heuristic, on this host on 2026-09-23, and quarantined it. The check then reports it missing. The build stores are excluded by `Sync-DefenderExclusions.ps1`; a bare-host export of either llama directory meets the same detection. Whether it is a false positive is unverified.
- ggml-vulkan compiles in Khronos Vulkan-Headers code, and the zip ships no Khronos licence text. Whether that creates a notice obligation is unverified.

**Evidence** (at b11115): the release's asset digest; `release.yml` 1137-1224 and 1876-1884; `ggml/src/ggml-backend-reg.cpp` 480-600; `ggml/src/ggml-vulkan/ggml-vulkan.cpp` 4959-4973 and 15853-15873; `src/llama.cpp` 222-256.

## MIGraphX and the ORT plugin EP (rocm lane, spike)

`-Variant rocm` builds `windows/Dockerfile.rocm-migraphx` (target `built`) on the merged rocm media, before the llama stage. `-NoRocmSpikes` skips it. cpu and nvidia never solve it, and no other Dockerfile or media build-arg map carries its pins.

What it produces:

| Path | Contents |
|---|---|
| `C:\runtime\lib\migraphx` (`MIGRAPHX_ROOT`) | AMD MIGraphX 2.17.0 (tag `rocm-10.0`, pinned by commit) built from source: `bin\migraphx*.dll`, `migraphx-driver.exe`, `migraphx-hiprtc-driver.exe`, `lib\cmake\migraphx`, headers |
| `C:\runtime\lib\onnxruntime-ep-amdgpu` (`ORT_AMDGPU_EP_ROOT`) | AMD's out-of-tree ONNX Runtime plugin EP `migraphx-ep.dll` ([onnxruntime/onnxruntime-ep-amdgpu](https://github.com/onnxruntime/onnxruntime-ep-amdgpu), commit on `gpuep-releases/gpuep-rel-2611`), built against the image's ORT 1.30.0, with its MIGraphX closure and TheRock's `amdhip64_7`/`amd_comgr`/`hiprtc*` beside it |

The MIGraphX stage leaves ORT and GenAI untouched. On this lane they are built with the cpu lane's feature flags plus DirectML, on the rocm sdk layer and with the rocm-lane `CMAKE_IGNORE_PREFIX_PATH`; nobody has compared their bytes with the cpu image's. The EP is built against that chain ORT and is loaded at run time with `onnxruntime.register_execution_provider_library(<name>, r"C:\runtime\lib\onnxruntime-ep-amdgpu\migraphx-ep.dll")`.

How it is built (`Build-MigraphxFromSource.ps1`, `Build-OrtAmdgpuEpFromSource.ps1`, helpers in `WindowsMigraphx.Common.psm1`):

- **Two compilers, on purpose.** MIGraphX has HIP device code, and the hub's clang-cl has no AMDGPU backend. MIGraphX therefore compiles with TheRock's `lib\llvm\bin\clang++.exe`, passed by absolute path; `lib\llvm\bin` never goes on PATH. Its host-only deps (abseil 20250512.0, protobuf v30.0, msgpack-c cpp-3.3.0, SQLite 3.50.4) build with clang-cl, as upstream's Windows CI does. The EP is host-only C++ and builds with clang-cl.
- **Targets are explicit.** `GPU_TARGETS` comes from `ROCM_WINDOWS_GFX_FAMILY` (`gfx120X-all` = `gfx1200;gfx1201`), never from a host probe.
- **Configuration no upstream CI builds.** rocMLIR is not in the TheRock tarball, so `MIGRAPHX_ENABLE_MLIR=OFF`. That costs the rocMLIR fusions (performance, not correctness). Also used: `BUILD_DEV=OFF` (hiprtc JIT), composable_kernel off, CMake 4.4.3, TheRock 10.0. Upstream's only Windows CI is build-only: gfx942, `BUILD_DEV=On`, ROCm 7.13.
- **CRT.** MIGraphX and its deps are `/MD`. The EP is `/MT`, as upstream forces it; it talks to ORT and MIGraphX only through C APIs.
- **Supply chain.** Every archive is SHA256-pinned in `versions.env` (`MIGRAPHX_WINDOWS_*`, `ORT_AMDGPU_EP_*`). The EP declares 8 FetchContent URLs (11 with DirectML) with no `URL_HASH`. Each one is pre-seeded through `FETCHCONTENT_SOURCE_DIR_*` from a verified archive, and so is the abseil that protobuf v34.1 fetches. The build refuses when the pinned commit declares a URL no pin rebuilds byte-for-byte, and `FETCHCONTENT_FULLY_DISCONNECTED` with CMP0170 turns any other fetch into a configure error. rocm-cmake is the one dependency with no archive pin. MIGraphX `rocm-10.0` calls `rocm_add_version_resource` (rocm-cmake 33541cd51f), and TheRock's rocm-cmake predates it by four commits: `Unknown CMake command`, 2026-09-25. So phase 2 reads the commit that MIGraphX's own `requirements.txt` pins, from the SHA256-pinned MIGraphX tree (`Get-MigraphxRocmCmakeCommit`, 40-hex only). It fetches exactly that commit with git, which verifies every object against the id (`Save-GitCommitSource`), and installs it into the deps prefix, which precedes TheRock on `CMAKE_PREFIX_PATH`. A MIGraphX bump carries its own rocm-cmake, with nothing to re-derive in `versions.env`. nlohmann_json stays TheRock's, through a two-file package shim in the deps prefix (`Write-NlohmannJsonConfigShim`). TheRock's copy was installed by an MSVC-style build, so its exported target lists `<prefix>/nlohmann_json.natvis` as an interface source, and TheRock's dist does not ship that file (`Cannot find source file`, 2026-09-25). The shim includes TheRock's config and clears that property.
- **Isolation.** The deps configure with the rocm-lane `CMAKE_IGNORE_PREFIX_PATH`. MIGraphX and the EP pass `-AllowRocmPrefix`, because they need hip, MIOpen, rocBLAS, hipBLASLt and hiprtc from TheRock.
- **Chain ORT only.** The EP build ends in the ORT build gate (`Assert-ChainOrtOnly -Consumer amdgpu-ep`, phase 5), which reads its configure log, `CMakeCache.txt` and `build.ninja` and writes the stamp the image census requires ([`onnxruntime-single-source.md`](onnxruntime-single-source.md)).

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
and the llama.cpp HIP zip carry copies of the same runtime; the Vulkan zip carries none.
Whether that runtime may ship in a **public** image is an owner decision to take before
`:winamd64-rocm` is pushed; `docs/deps/deps.json` records it as
`LicenseRef-Proprietary-EULA` until then.

The Vulkan loader is LunarG's signed build of the Khronos Vulkan-Loader, Apache-2.0 with
MIT parts; its `VulkanRT-License.txt` ships in `C:\vulkan-loader`. The DXC pair beside the
chain ORT carries Microsoft's licence terms (`LICENSE-MS.txt`) next to NCSA, the same
review question as the LiteRT-LM copy. `ai-edge-litert`'s wheel ships no licence or NOTICE
text of its own.

## Open points

- **HIP inside a Windows container** is unproven and cannot be measured on this host
  (build skew). GStreamer's `gsthip` cannot load in any Server Core container on any lane
  at all: it links `gstgl`, which imports `OPENGL32.dll`.
- **GPU correctness:** upstream TheRock#8379 reports torch+ROCm returning zeros on the
  RX 9070 XT. Compare every GPU path against its CPU result on the bare host.
- **The spikes are first builds.** MIGraphX with `MLIR=OFF`, `BUILD_DEV=OFF`, gfx120X and
  TheRock 10 is a configuration no upstream CI builds; TVM's ROCm runtime includes
  TheRock's HIP headers from clang-cl for the first time, on a minimal LLVM with AMDGPU
  that has never been built in the image; Dawn and Tint have never compiled under the
  image's clang-cl.
- **The 2026-09-23 additions have not run in a container.** That covers the OpenCL ICD
  registration, the Vulkan loader, FFmpeg's Vulkan build, the llama.cpp Vulkan zip,
  gfx1200 and `ai-edge-litert`. The host evidence is partial; see each section's
  Evidence. FFmpeg's Vulkan build produced object files only, through gcc. The gfx1200
  wheels were hashed, not installed. Unit tests cover the rest.
- **Found on every lane, not fixed here (owner decision):** LiteRT-LM is cloned by tag,
  not by commit. OpenCV's configure-time ORT download, listed here until 2026-09-23, was
  a Windows-lane defect (Linux pre-set `HAVE_ONNXRUNTIME` all along) and is fixed on every
  Windows lane ([`onnxruntime-single-source.md`](onnxruntime-single-source.md)).
