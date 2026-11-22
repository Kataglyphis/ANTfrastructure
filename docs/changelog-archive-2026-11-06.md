# Changelog archive: 2026-11-05 … 2026-11-06

Later entries are in [the 2026-11-07 … 2026-11-12 archive](changelog-archive-2026-11-12.md);
earlier entries remain in the older archives listed by [the current changelog](../CHANGELOG.md).

## 2026-11-06 — IREE builds outside the 20 GB RUN scratch

- The amd64 media-tvm stage failed with `No space left on device` in IREE's compiler wheel while
  the host had 65 GB free: every Windows RUN gets a sandbox of about 20 GB, and IREE with LLVM
  in-tree left 0.3 GB. Its build tree now lives on the RUN's `iree-build-winamd64` cache mount at
  `C:\iree-build`, emptied before configure and after the wheels; a checkout run keeps the old tree.
  Each wheel logs the free space it starts with. `SourceBuild.IreeScratch.Tests.ps1` and six
  mutations hold the path on both sides, the resolver and both resets.

## 2026-11-06 — develop is green again after the Windows image fixes

- The push of `b2b906d8` turned Linux preflight, eight mutation shards and the Windows patch-drift
  job red (#234, #235). The Windows suites behind the new recipes failed on Linux pwsh, where CI
  proves them: the meson provenance case and the MSVC notice suite now use separators and an
  interpreter every host has, and the cases that need Windows (cmd.exe, VsDevCmd, the twin builds)
  moved to `TorchApp.SdistCompilerVs.Tests.ps1`, leaving the recipes on `SourceBuild.IreeTwin.Tests.ps1`.
- `LIBVPX_MESON_SHA256`, `DIRECTML_NUPKG_SHA256` and `LIBVPX_VERSION` are classified in
  `bump_versions.py`; `genai-guidance-smoke.py` passes ty. New duplication was refactored away rather
  than budgeted: `Get-BinDllProvenanceEntry` (OpenSSL and the MSVC runtime), `Add-IreeNinjaTuFlag`,
  and `WindowsPythonApp.Common` re-exporting the notice API. Two allowlist rows became stale and left.
- The drift check maps `002-libvpx-clangcl-simd-flags.patch` to the libvpx meson port at
  `LIBVPX_MESON_COMMIT`, which the wrap applies it to, instead of GStreamer's tree.
- The libvpx patch's repo now lives in the drift check's one repo map (`Patches`), not a second table
  whose parameter duplicated another suite's signature; the TensorRT and MSVC-notice recipe families
  are declared in `gate-proofs.allow`.
- `wsl-quality.sh check` hands the suites one absolute interpreter path: 108 of them run
  `"${PREFLIGHT_PYTHON}"` quoted, so the multi-word `uv run ... python` exited 127 in each.
- Still red until `:winarm64` is published again (#236): the device gate runs the published bundle,
  which predates libvpx (`no element "vp8enc"`) and the onnxinference wide-path fix (0xC0000005).

## 2026-11-06 — Windows packages carry the MSVC runtime's notice

- A ZIP, MSIX or MSI that carries the VC++ runtime ships `licenses/msvc-runtime/Redist.txt` and a
  `README.txt` with the end-user notice and the learn.microsoft.com link; the wording is a draft for
  review. CPack installs both and adds the notice to the WiX licence page; `New-PortableBundle` and
  the Python app bundle stage them; `Assert-PackageMsvcRuntimeNotice` fails a finished package with
  the runtime and without the notice (`WindowsMsvcRuntimeNotice.Common.psm1`, CON228;
  `Msvc.RuntimeNotice.Tests.ps1`, `test-cmake-windows-arch.sh`, four `msvc-notice` recipes).

## 2026-11-06 — ORT's LLM kernels compile through sccache on Windows

- `onnxruntime_providers_cuda_llm`, the last CUDA target on bare nvcc, keeps the sccache launcher:
  `Get-OrtPtxLauncherExemptArg` and `sccache-ptx-exempt.cmake` are gone. The hub's sccache build
  carries mozilla/sccache#2809, and in the nvidia toolchain image it compiled `sm_86` plus PTX-only
  `compute_120` without `Missing "cubin" file output`, warm 5 of 5 from the cache.
  `SourceBuild.OrtCudaLauncher.Tests.ps1` refuses an exemption's return
  (`lib.ort-cuda-launcher-no-exemption`, `sccache.ptx-only-pass-runs-uncached`). The chain proof
  (provider link from hits, smoke gate, `Test-Cache.ps1`) comes with the next nvidia chain.
- v0.19.0 is exactly `SCCACHE_SOURCE_REV` and carries #2876; #2809 merged on 2026-11-02 and is in no
  release yet, so the hub's build stays (`shared/upstream/sccache/README.md`).

## 2026-11-06 — The Windows nvidia lane downloads TensorRT and fails without it

- `Install-Tensorrt.ps1` guessed the pre-11.x file names, which 404 for TensorRT 11, so every
  `-Gpu` image shipped without TensorRT while the log read "Continuing WITHOUT TensorRT". It now
  downloads `TensorRT-Enterprise-<ver>-Windows-amd64-cuda-<cuda>-Release-external.zip` from
  `developer.nvidia.com/downloads/compute/machine-learning/tensorrt/`, for the image's CUDA line
  only, and grades it with the unchanged `TENSORRT_ZIP_SHA256`: the 11.4.0.106 zip fetched on the
  host on 2026-11-06 hashed to the pin. A staged zip in `windows/downloads/` still wins.
- No TensorRT now fails the nvidia lane (owner, 2026-11-06): the installer and `Set-TensorrtTree.ps1`
  throw, and the smoke gate fails an `-ExpectGpu` image with an empty `TENSORRT_ROOT`
  (`host.trt-url-tensorrt11-scheme`, `host.trt-missing-throws`, `smoke.trt-required-expect-gpu`).
  The runtime-only rule is unchanged. Windows arm64 TensorRT stays off as an owner decision (CON230).

## 2026-11-06 — QNN's Hexagon skeletons are DSP payload, and NVIDIA's gst plugins are recorded

- The first green arm64 nvidia package stage reached the runtime-image smoke, which failed on 107 QDSP6 objects
  under `onnxruntime-cpu/lib/hexagon-v*/`: the HTP backend's skeletons, run by the DSP, never by the image's
  loader. The tree-arch scanner skips those dirs and names machine 164 `QDSP6` (`tree-arch.hexagon-skels-are-dsp-payload`,
  `tree-arch.hexagon-filter-is-narrow`). The five `libgstnv*.so` plugins that need the driver's `libcuda.so.1` are
  recorded per arch in `_PARITY_GST_KNOWN_BROKEN` (`runtime-smoke.nvidia-gst-plugins-recorded`,
  [failure-modes.md](failure-modes.md#tree-arch-usrlocallibonnxruntime-cpu-ships-107-em164-objects-on-arm64)).

## 2026-11-06 — A required `rustup … add` is retried under qemu-user

- The arm64 package stage of the nvidia chain died in `rustup component add rustfmt` with a qemu-user SIGABRT
  mid-download, a step the three runs before had passed. `rustup_required` in `install-rust.sh` runs each of the
  four required adds up to three times and fails the installer after the third (`rust.rustup-required-retries`,
  `rust.rustup-required-propagates`,
  [failure-modes.md](failure-modes.md#rustup-component-add-aborts-under-qemu-user)).

## 2026-11-06 — The SBSA RUNPATH starts with `$ORIGIN`, and the CUDA SONAMEs come from the host toolkit too

- The fourth arm64 package stage left 15 closure rows with every element registering: nine were
  `libnvdsgst_deepstream_bins.so` NEEDing its sibling plugins in `gst-plugins/`, out of reach of a RUNPATH that
  names `lib/` alone, and six were still bare `libcufft.so`, `libcublas.so`, `libnppial.so` and `libnppist.so`,
  because the staged arm64 runtime holds only cudart's dev link. `ds_sbsa_runpaths` now writes
  `RUNPATH=$ORIGIN:…/lib`, as the amd64 Makefiles do, and `ds_sbsa_cuda_soname` reads the SONAME from the target
  view or the host toolkit of the same version (`deepstream.sbsa-origin-runpath`, `deepstream.sbsa-host-cuda-sonames`,
  [failure-modes.md](failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-06 — The SBSA bufferpool is staged under its SONAME, and every bare CUDA NEEDED is rewritten

- The third arm64 package stage left 24 closure rows and four elements that "do not register" from
  `/nonexistent`: the SBSA container ships `libnvdsbufferpool.so` bare, and nothing that NEEDs
  `libnvdsbufferpool.so.1.0.0` resolved it; `libcublas.so`, `libnppial.so` and `libnppist.so` were NEEDed
  bare like `libcufft.so`; and the UCX, Maxine and bare-bufferpool excuses were STALE on a `.deb` without those
  files. `ds_stage_sbsa_libs` copies the bufferpool under its SONAME with the bare link, `ds_sbsa_runpaths`
  rewrites every bare NEEDED to the target CUDA dev link's SONAME, and the amd64-only excuses are gated per arch
  (`deepstream.sbsa-bufferpool-soname`, `deepstream.sbsa-bare-cuda-needs`, `deepstream.sbsa-amd64-excuses`,
  [failure-modes.md](failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-06 — The SBSA DeepStream files get RUNPATHs and link TensorRT 10

- The second arm64 package stage failed DeepStream's soname closure (105 rows) and found `nvinfer` linked
  `libnvinfer.so.11`. The Jetson `.deb`'s files carry no RUNPATH (L4T's `ld.so.conf` has the tegra dir) and NEED a
  bare `libcufft.so`; `ds_sbsa_runpaths` now sets `RUNPATH=…/deepstream-9.1/lib` on every file without one and
  rewrites that NEEDED to `libcufft.so.12`, as the amd64 `.deb` carries. The TensorRT 10 SDK's `-L` precedes the
  sysroot flags on the cross compiler word, and the three VPI consumers are excused on arm64 only
  (`deepstream.sbsa-trt-sdk-before-sysflags`, `deepstream.sbsa-runpaths-set`, `deepstream.sbsa-vpi-excused`,
  [failure-modes.md](failure-modes.md#broken-libgst-pluginslibgstnvvideoconvertso---libnvbufsurfaceso100-on-the-arm64-package-stage)).

## 2026-11-05 — The arm64 package stage links DeepStream into the multiarch plugin dir

- The first arm64 package stage of the nvidia chain died on `no GStreamer plugin directory at
  /opt/gstreamer/lib/aarch64-linux-gnu/gstreamer-1.0`: `ds_stage_runtime` built the path from the host's multiarch
  triplet, but the cross-built GStreamer installs into `lib/` with no triplet directory. The link now lands in
  `lib/multiarch/gstreamer-1.0`, the directory `GST_PLUGIN_PATH` names on every arch
  (`deepstream.plugin-dir-multiarch-link`,
  [failure-modes.md](failure-modes.md#no-gstreamer-plugin-directory-at-optgstreamerlibaarch64-linux-gnugstreamer-10)).

## 2026-11-05 — Cerbero's curl gets a stall timeout

- The amd64 android stage hung 80 minutes in `mpg123 -> fetch`: a sourceforge mirror stopped sending after 225 KB and
  cerbero's curl, which has a connect timeout but no stall timeout, waited on the open socket. The fetch retry now
  arms `speed-time = 60` / `speed-limit = 1024` through a `.curlrc` under `CERBERO_HOME` (`CURL_HOME`), so a stalled
  transfer fails and cerbero's retry and mirror take over (`lib.cerbero-curl-stall-timeout`,
  [failure-modes.md](failure-modes.md#cerbero-a-fetch-hangs-for-hours-on-a-stalled-mirror)).

## 2026-11-05 — The DeepStream build hits sccache

- Both arches' DeepStream steps reported `156 requests, 0 hits, 109 misses` on every chain: the sources were cloned
  into a `mktemp -d` tree, and sccache hashes the preprocessed source whose line markers carry that path. The build
  tree is now `${TMPDIR:-/tmp}/deepstream-build`, emptied first (`deepstream.build-dir-stable`,
  [build-cache-tiers.md § 7](build-cache-tiers.md#7-do-not-repeat-list)).

## 2026-11-05 — sccache gives way when the shared disk runs short

- The VPS disk had 19 GB free with Nextcloud and its backups on it, and an hourly check at a 100 GiB cap left too little
  margin. The cap is 60 GiB, checked every 10 minutes, and `sccache-s3-evict` now also shrinks the bucket when the disk
  has under 25 GiB free (`MIN_FREE_GB`), down to `FLOOR_GB`, without deleting again for space a resync is still freeing.
  A 70 GiB bucket quota and 5 GiB of ext4 reserved blocks hold the rest; nothing here limits Nextcloud
  ([size cap](../linux/sccache-s3/README.md#4-the-size-cap)). `test-sccache-evict.sh` covers it.

## 2026-11-05 — The sccache size cap deletes again

- `sccache-s3-evict` failed on every run over the cap and deleted nothing: its `awk` left early, `sort` died of
  SIGPIPE, and `pipefail` ended the script before `s5cmd run`. It first bit on 2026-11-04, when the bucket passed
  100 GiB for the first time, and the bucket kept growing on the disk it shares with Nextcloud. `awk` now reads to the
  end. The live server carries the fix and cut the bucket from 104.0 to 90.1 GiB. `test-sccache-evict.sh` runs the
  script's real text against stubs, and `lib.sccache-evict-reads-whole-list` proves it
  ([failure-modes.md](failure-modes.md#sccache-evictservice-fails-with-sort-write-failed-standard-output-broken-pipe)).

## 2026-11-05 — The SBSA DeepStream build finds the target's multiarch headers

- The first arm64 media builds of the nvidia chain (CON42 phase 7) died in civetweb on `zconf.h`: the cross GCC's
  sysroot is `/usr/aarch64-linux-gnu`, so apt's `:arm64` headers under `/usr/include` are invisible to it, and
  DeepStream's Makefile builds carry no cross file. `ds_cross_setup` now appends the `-idirafter` pair cross-meson
  uses plus `-L/usr/lib/<triplet>` to the cross compiler strings (a first attempt on `CPATH` named the wrong dir),
  `zlib1g-dev` is a named build package, a failed civetweb prints its error lines, the component Makefiles'
  `TARGET_DEVICE=aarch64` branches (install into and `-L` L4T's `/usr/lib/<triplet>/tegra`) get an explicit
  `LIB_INSTALL_DIR` and a build-time link to DeepStream's lib dir (`deepstream.sbsa-lib-install-dir`), the cross
  components get the CUDA view's `lib64` and `lib64/stubs` as explicit `-L` (a cross GCC ignores `LIBRARY_PATH`,
  so `nvll_osd` could not find `-lcuda`), `gst-dsexample`'s sub-make gets `$(CC)` for its literal `gcc`
  (`deepstream.dsexample-literal-gcc-patched`), `libgstnvdsseimeta.so.1.0.0` is the fourth staged SBSA copy
  (nvmultistream2 links it; no arm64 `.deb` ships it; the SBSA container's Tegra dir does), and
  `deepstream.cross-multiarch-headers` proves the include pair
  ([failure-modes.md](failure-modes.md#zconfh-no-such-file-or-directory-in-civetweb-under-the-sbsa-deepstream-build)).

## 2026-11-05 — The ARM SDK pins move with the Renovate call; QNN on arm64 needs no staged zip

- Android NDK r30 (`30.0.16248370`), LiteCore v1.2.0 (the archive LiteRT main builds against) and
  QAIRT 2.51.1.261002, the public "Qualcomm AI Runtime Community" zip, are pinned in `versions.env`.
  The LiteCore pin left `build-android.sh` for `LITECORE_VERSION`/`LITECORE_SHA256`, forwarded by
  `Dockerfile.android`, and the archive comes through the asset mirror (CON227 done).
- `resolve_qnn_sdk` fetches the pinned Community zip into the `qnn-sdk-<arch>` cache mount every
  QNN-resolving media RUN now carries (GenAI's verify RUN too, and the ORT gate grades that root by
  default), so the arm64 image builds the ORT QNN EP without a hand-staged
  zip; a zip in `linux/qnn-sdk/` overrides it and must match the pin, `QNN_SDK_SOURCE=drop` keeps
  the old contract. The Community licence allows object-code distribution as part of a product only;
  the image ships the backend `.so` files as before ([qnn-linux.md](qnn-linux.md#staging)).
- The Windows lane does the same: `Resolve-QnnSdk` fetches the pinned Community zip (its `lib\aarch64-windows-msvc`)
  into the `qnn-sdk-winamd64` cache mount of the four QNN RUNs of `Dockerfile.media-builder` when `windows/qnn-sdk`
  holds no zip; one pin (`QNN_SDK_VERSION`, `QNN_SDK_ZIP_SHA256`) serves both lanes, so the Linux-only key is gone.
  `SourceBuild.QnnCommunityZip.Tests.ps1` covers the fetched branch with a handed-in fetch; the Windows lane proves it.
- `bump_versions.py` gained `spec_android_ndk`, `spec_litecore` and `spec_qnn_sdk` (the vendors list
  nothing, so LiteRT main is the oracle for the two SDKs), and `renovate-local.sh` runs the sweep in
  the same call: `--check` on report, `--write` plus `sync_versions.py --write` on apply, `--no-bump`
  opts out ([the sweep rides the Renovate call](dependency-updates.md#the-sweep-rides-the-renovate-call)).
  Suites: `test-qnn-community-zip.sh`, `test-litecore-pin.sh`, `test-renovate-pin-sweep.sh`, three
  offline spec cases; eight recipes bite.

## 2026-11-05 — The nvidia lanes stop erasing each other's apt lists

- The rebuild's nvidia chain (amd64 + arm64 SBSA, `--parallel-archs`) failed its arm64 gpu stage with
  `Unable to locate package cuda-cross-sbsa-13-4` right after enabling that repo: both lanes shared the
  `apt-lib-amd64` cache mount, and the amd64 lane's `apt-get update` deleted the cross-linux-sbsa lists.
  `Dockerfile.nvidia` keys its apt caches by the target too, as every other Dockerfile does, and because
  BuildKit's cache key ignores a cache mount's id (the re-keyed repo RUN stayed `CACHED`, the new mount was
  empty), `install-cuda-stack.sh` refreshes the lists before its first install. `test-cuda-cross-sbsa.sh`
  refuses both regressions; `cuda-stack.apt-lists-keyed-by-target` and `cuda-stack.installer-refreshes-apt-lists` prove it
  ([failure-modes.md](failure-modes.md#the-cross-sbsa-packages-vanish-between-the-repo-run-and-the-install)).
  The default chain (three arches) and the rocm chain passed in the same sequence.
- The push before it (8dcc7d6f) left `develop` red (issue 227): `GENAI_TINY_MODEL_PY` is registered as the
  in-container name of the tiny-model source, not an operator knob; the two in-container command generators
  (`smoke_app_wheel_command`, `smoke_python_probe_command`) live in `smoke-common.sh` beside the payloads they wrap,
  so `smoke-runtime-image.sh` stays under its frozen size; and `lib.genai-smoke-tiny-missing-fails` names one edit
  again now that the wheel smoke reads the generator the same way the GenAI probe does.

## 2026-11-05 — The runtime smoke hands OrchestrANT's wheel check its GenAI model

- OrchestrANT's `orchestrant.smoke` (2026-11-01) decodes the model `ORCHESTRANT_SMOKE_GENAI_MODEL` names and only
  warns without one, so the rebuild's amd64 runtime-image smoke counted 14 of 15 and failed its floor.
  `check_app_wheel_smoke` now writes `lib/tiny-genai-model.py`'s model in-container and names it
  ([the app-wheel floor](gen1-riscv64-genai.md#the-app-wheel-floor)); `boot.genai-model-named-for-wheel-smoke` pins it.
- The arm64 package stage's `rustup target add aarch64-linux-android` died once under QEMU 10.2.3 with signal 6
  (abort, no message) while the host pushed amd64 and built riscv64; the same command in a plain arm64 container
  on that host ran twice without fault, and the rerun passed. Recorded, not changed.
