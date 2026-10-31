<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Python app bundles — a consumer's app as a relocatable folder

**What this gives a Python consumer:** one folder that holds its own CPython, exactly the
locked wheels, the chain ONNX Runtime, the app's data and one launcher per console script.
It runs from any directory on a host with no Python installed, and the packagers
(zip/MSI/MSIX, tar.gz/deb/AppImage) wrap that folder; they do not rebuild it.

It is not PyInstaller or Nuitka. Nothing is frozen or recompiled, so the bundle runs the same
wheels the consumer's CI tested, the Cython-compiled app wheel included.

| Lane | Builder | Runtime |
|---|---|---|
| Windows (`:winamd64`) | [`windows/scripts/python/New-PythonAppBundle.ps1`](../windows/scripts/python/New-PythonAppBundle.ps1) | the image's own source-built CPython, laid out by `PC\layout` |
| Linux (`:latest`) | [`linux/scripts/06-packaging/python-app-bundle.sh`](../linux/scripts/06-packaging/python-app-bundle.sh) | the image's own source-built CPython, staged as a movable tree by [`python-relocate.py`](../linux/scripts/06-packaging/python-relocate.py) ([below](#the-relocated-image-cpython)); `--python-runtime standalone` takes python-build-standalone via `uv python install` instead, on a host without the image |

First consumer: OrchestrANT (`yolo-monitor`, `orchestrant-bench`, `orchestrant-smoke`).
Measured on 2026-09-30/10-01: Windows 561 MB, Linux x86_64 666 MB. Both builders were also
proven by moving the bundle elsewhere and running it again.

## The consumer's side: `packaging/app.json`

```json
{
  "name": "OrchestrANT",
  "id": "orchestrant",
  "distribution": "OrchestrANT",
  "license_file": "LICENSE",
  "extras": ["app"],
  "chain_opencv": true,
  "scripts": ["yolo-monitor", "orchestrant-bench", "orchestrant-smoke"],
  "data_env": "ORCHESTRANT_DATA_DIR",
  "data_dir": "share/orchestrant",
  "data": [{ "from": "resources/models/deim_dfine_n_coco.onnx", "to": "share/orchestrant/models/deim_dfine_n_coco.onnx" }],
  "self_test": ["yolo-monitor", "--self-test"]
}
```

`name`, `id`, `distribution`, `extras`, `data_env`, `data_dir`, `license_file` and `self_test` are required.
The packagers read `description`, `publisher`, `homepage`, `license_file`, `icon`,
`gui_script` and `msi_upgrade_code`.
The Linux and Windows builders validate the declared project license before
resetting an existing bundle, and stage its original text at `LICENSE`. A missing,
empty or whitespace-only source fails. Linux copies carry
`lib/app-packaging-license.sh` and `lib/log-bootstrap.sh`; Windows copies of `WindowsPythonApp.Common.psm1`
carry `WindowsIcon.Common.psm1` and `WindowsMsix.Common.psm1`.
When `icon` is set, the Windows builder compiles it once and links the resource
into each launcher; an omitted icon retains the old behavior. `WindowsIcon.Common`
imports `WindowsMsix.Common` and its `WindowsScripts.Shared` companion to decode
the PNG and reject corrupt or fully transparent images.
An app that runs GStreamer adds a `gstreamer` block (Linux; [below](#gstreamer)).

What the app itself must do:

- **Find its data through `data_env`.** Each launcher sets that variable to `<bundle>/<data_dir>`,
  and overrides any value the caller set, so a bundle always reads its own data. Overrides
  belong in an app-specific variable (OrchestrANT: `ORCHESTRANT_MODEL`). Never look for data
  relative to the source tree.
- **Write logs to a user directory**, not beside the code. An installed bundle is read-only.
- **Answer `self_test` with a JSON object** on stdout, as the last block that runs from a bare
  `{` line to a bare `}` line, with `"ok": true`. If it includes `onnxruntime_module`, the
  Windows builder also checks that the path lies inside the bundle. The block rule exists
  because ONNX Runtime prints notices containing braces before the report: on a host without a
  GPU, the DirectML provider prints one when it falls back to CPU.
- **Keep an extra that installs only what the app needs.** OrchestrANT's `app` extra asks for
  `opencv-python>=5` and declares conflicts with every `ml-ai*` extra. Without those
  conflicts, uv reuses the riscv64 git build of opencv-python (4.13) from other forks.

## What the builders do

The Linux drivers source the sibling `python-app-cli.sh`. It owns shared option parsing while
each driver retains its defaults and usage. Bundle-only options remain invalid for packaging,
and packaging's `--no-test` remains invalid for bundling. Keep the sibling with the drivers;
normal hub and submodule checkouts already provide it.

Both run in the family image, from a built app wheel (`--wheel-dir`, default `dist`):

1. **Runtime.**
   - Windows: `PC\layout --include-stable --include-venv --precompile`, then empty
     `Lib\site-packages`, because the layout copies the image's own packages along with it.
   - Linux: the image's `/usr/local` CPython, staged and checked by `python-relocate.py`
     ([§ The relocated image CPython](#the-relocated-image-cpython)). It is the interpreter
     that built the wheels, so the version cannot drift and nothing is downloaded.
2. **Packages.**
   - `uv export --locked --extra <extras>`, then install into the runtime. Both lanes leave
     PyPI `onnxruntime` out of the export: its 1.31.0 release has no CPython 3.15 wheel, so
     resolving it first fails before a later replacement could run.
   - Linux omits the ORT provider packages present in `uv.lock` with `--no-emit-package`
     and passes the chain wheel to the first `uv pip install` alongside the remaining locked
     requirements. Locked transitive dependencies and the separate GenAI distribution remain.
   - The app wheel goes in with `--no-deps`; the compiled wheel wins over the pure one.
     It must carry the runtime's ABI tag (`cp3XY`, or `abi3`), so the `cp3XYt` twin beside it
     is never taken. A `cp3XYt` wheel alone is refused, not swapped for the pure one
     (`Select-PythonAppWheel`, and `select_app_wheel` in `python-app-bundle.sh`).
   - The runtime's `onnxruntime` comes from the chain wheel. See
     [`onnxruntime-single-source.md`](onnxruntime-single-source.md).
3. **Chain OpenCV** (Windows, `"chain_opencv": true`). The next section explains it.
4. **Launchers.**
   - Windows: a small C program per script (`windows/scripts/python/app-launcher/launcher.c`),
     compiled with clang-cl `/MT`. It starts `runtime\python.exe -I` on the entry point and
     passes the arguments, Ctrl+C and the exit code through. A job object makes the child die
     with the launcher.
   - Linux: a shell script in `bin/`.
5. **Data**, copied as `app.json` lists it.
   - The Windows builder keeps launcher selection and data copying in separate steps; a
     fixture checks requested console scripts, missing names and the copied payload path.
6. **Native closure.**
   - Windows: the VC++ runtime goes beside `python.exe`.
   - Linux: `python-app-closure.sh` copies every missing shared library into `runtime/lib` and
     gives each user an `$ORIGIN` RUNPATH.
   - Linux: `bundle-loader.sh --beside` puts the image's loader and glibc in front of the
     runtime's interpreter (below, *The image's glibc travels*).
7. **Gates**, all fatal:
   - **Import walk** (Windows): `Test-TargetArch.ps1 -ImportWalk -Standalone`. Every DLL that
     any binary imports must be in the bundle or ship with Windows. `-Standalone` makes the
     walk fatal on a native lane, as it is on a cross lane: a bundle has no image `PATH`
     behind it.
   - **G6**: the bundle's ORT is byte-identical to the chain build.
   - **The self-test**, run from the finished bundle; on Linux twice, the second time through the
     bundled loader (`KATAGLYPHIS_BUNDLED_GLIBC=1`), as on a host with an older glibc.
8. **`bundle.json`**: the wheels, the Python version, the bundled glibc's version (Linux) and the
   self-test report.

### Linux GPU bundles

A Linux NVIDIA or ROCm image requires its respective CUDA or MIGraphX execution provider in
the self-test's `available_providers` report, including the packaged launchers. This permits a
build without GPU hardware; it does not prove GPU inference. `PYTHON_APP_REQUIRE_PROVIDER`
can require a provider explicitly and must agree with the image variant. The bundle manifest
records the requirement, and a package from that bundle cannot use `--no-test` to bypass it.
On a host with a compatible GPU, set `PYTHON_APP_REQUIRE_ACTIVE_PROVIDER=true` while running the
packager to require the provider in the actual inference session. A CPU fallback then fails, but
session activation alone does not prove that any operator ran on the GPU. Profile an inference
with a GPU-supported operator and confirm its placement before releasing the package.

By default the ELF walker resolves transitive dependencies from the image and refuses
external absolute `NEEDED` paths. This static closure does not prove that dynamically loaded GPU
assets travel with the package, nor does it cover third-party licence inventory. Verify those
assets and notices and run the package on a clean host with the compatible vendor driver and GPU
before distributing it. The build container's GPU SDK or its available-provider list alone is not evidence of GPU inference or a portable package.
The default CPU bundle path is unchanged.

`PYTHON_APP_HOST_GPU_RUNTIME=true` instead leaves the selected CUDA or MIGraphX provider's
vendor libraries to the host. The option requires a GPU provider and a matching SDK tree in
the build image. The builder matches the core, shared bridge and selected provider to one
unstripped wheel, reads the provider's direct imports, refuses unknown imports, records their
exact vendor SONAMEs in `bundle.json` and `REQUIRES-GPU-RUNTIME.txt`, and rejects accidentally
bundled SDK libraries. If a CUDA wheel also contains the TensorRT provider, its bytes must match
that same wheel; its additional direct imports are recorded separately as optional TensorRT
host requirements, not as CUDA requirements. The selected CUDA and optional TensorRT providers
remain in the package, while their vendor SDK libraries stay on the host. A library listed as an
additional TensorRT import can still be needed dynamically by another provider. It preserves nonempty `LD_LIBRARY_PATH` entries
through either bundled-loader path. The installed host needs a compatible GPU driver and
CUDA/cuDNN or ROCm/MIGraphX runtime, including dynamically loaded assets; the package does
not install that runtime. CUDA and MIGraphX package filenames carry `-gpu-nvidia` and
`-gpu-amd` respectively. The installed application ID stays the same, so a GPU DEB replaces
the CPU DEB rather than installing beside it. Provider-wheel notices, clean-host tests and
actual GPU inference remain the consumer's responsibility.
The reusable `python-ci-linux.yml` workflow exposes this as the boolean
`host-gpu-runtime` input, defaulting to `false`. A GPU caller also sets
`gpu-artifact-label` to `nvidia` or `amd` and supplies `container-image`. The lane
requires the corresponding provider and permits NVIDIA on x64/arm64 and AMD on x64.
`app-python-runtime` defaults to `image`; a GPU inventory may explicitly select
`standalone` when its image lacks a relocatable CPython. The standalone interpreter
is downloaded for the image's Python version, so its native dependencies and license
inventory must be checked from the resulting package.
Before pulling the GPU image it requires `packaging/app.json` and a hub pin with the
GPU bundle and package APIs. It skips docs publication, uses full runner cleanup and
requires a vendor-matched tar, DEB and AppImage. Its uploads are named
`unverified-gpu-*` and occur only after the build succeeds. Image size may still exceed
hosted-runner storage; the lane and finished packages need a real run, complete notice
checks and GPU execution before release.

```powershell
# Windows, inside :winamd64
& <hub>\windows\scripts\python\New-PythonAppBundle.ps1 -RepoRoot <repo> -WheelDir dist -OutDir dist\windows-x64\bundle
```

```bash
# Linux, inside :latest
bash <hub>/linux/scripts/06-packaging/python-app-bundle.sh --repo-root <repo> --wheel-dir dist --out-dir dist/linux-x86_64/bundle
```

Windows app staging shares literal directory setup through
`Initialize-PythonAppDirectory`, backed by `WindowsScripts.Shared`.
`New-PythonAppWorkDirectory` preserves caller paths, temporary defaults and output
creation order. `Get-PythonAppWheelFile` enumerates direct matching files only;
callers keep their ABI/name predicates and first-match or unique-wheel verdicts.
Keep the Shared companion when copying these modules; reset and allocation
failures terminate before packaging proceeds.

## The relocated image CPython

The image's GIL CPython (`/usr/local`, `--enable-shared`) is not movable as installed: its
interpreter finds `libpython` through `ld.so.conf`, and `_sysconfigdata` names `/usr/local`.
`python-relocate.py stage --python <python3> --dest <runtime>` copies it and fixes both:

- The interpreter gets the RUNPATH `$ORIGIN/../lib`. `bundle-loader.sh` keeps that entry
  pointing at the same directory when it moves the binary beside the loader.
- `_sysconfigdata` gets a block that replaces the build prefix with `sys.base_prefix` at
  import, as a whole path component (`-I/usr/local/include` moves, `/usr/localfoo` does not).
  Native trees keep the module beside the stdlib; the cross-built arm64 and riscv64 trees keep
  it in `lib-dynload`, so `stage` takes the path the interpreter imports. The stale `.pyc` and
  the `_sysconfig_vars_*.json` twin, which nothing reads at run time, are removed.
- `python-3.X.pc` gets `prefix=${pcfiledir}/../..`; `python3.X-config` relocates itself.
- Left out: the system `site-packages` (pip), `pip3.X`, the static `libpython3.X.a`, and the
  `readline` binding, which links GNU readline (GPL-3) and serves only an interactive REPL.

`stage` refuses a static build, a distribution interpreter (`/usr`) and an existing
destination. `python-relocate.py check --tree <runtime>` copies the tree to a fresh directory,
runs it there with `-I`, imports ssl, sqlite3, ctypes and zlib, and fails when:

- `sys.prefix`, `sys.base_prefix` or `os.__file__` lies outside the copy;
- `/proc/self/maps` shows `libpython` mapped from anywhere else (the image's `/usr/local/lib`
  would satisfy a missing RUNPATH silently);
- a string sysconfig variable still names the build prefix or the unmoved tree;
- an ELF file has an absolute RUNPATH, cannot be read, or links `libreadline`.

The bundle builder runs both, and the runtime smoke's `RELOCATABLE-PY` row runs both on every
arch's shipped image. Measured on 2026-10-26 against the published children of `:latest`:
the stage takes about 5 s and 305 MB on amd64. The row passed on amd64 (7 s), arm64
(20 s, QEMU) and riscv64 (54 s, QEMU). A test bundle built in `:latest` amd64 under
`--network none`, with a warm uv cache for its PyPI dependencies, downloaded no CPython, and
its self-test passed after the bundle was moved.

What `check` does not cover: build-directory strings in compiler flags (`-ffile-prefix-map`
and the like), and the compiler names a cross tree's sysconfig records. Neither matters for
installing wheels; an sdist built against the bundle runtime would read them
([`consumer-image-contract.md` § The free-threaded Python](consumer-image-contract.md#the-free-threaded-python)
fixes the same names for the twin). Tests: `linux/scripts/tests/test-python-relocate.sh`.

## Windows: the image's OpenCV, not PyPI's

PyPI's `cv2.pyd` imports `MFPlat.dll`, `MF.dll` and `MFReadWrite.dll` (Media Foundation).
Server Core, and so the image, has none of them, and neither do Windows N editions, so
`import cv2` fails there with `DLL load failed`. The image builds its own OpenCV 5 with Win32 UI,
FFmpeg and DirectShow, and no Media Foundation. `chain_opencv` puts that one into the bundle,
and `Sync-UvChainOpenCv` puts it into the consumer's Windows CI venvs.

**Copying the package is not enough.** The image's `cv2\config.py` names only OpenCV's own
`bin`, yet the build also imports the chain ORT (`opencv_dnn`, `opencv_gapi`) and five FFmpeg
DLLs (`opencv_videoio`), which live in `C:\runtime\ffmpeg\bin`. Inside the image, a
`sitecustomize.py` in the base site-packages registers all those directories with
`os.add_dll_directory`. Python ignores `PATH` for an extension's dependencies (≥ 3.8). A venv
does not run that `sitecustomize.py`, and neither does a bundle. Measured on 2026-10-01: the
copied package failed with `DLL load failed while importing cv2` in both. The PE walk then
showed `avcodec-63`, `avformat-63`, `avutil-61`, `swscale-10` and `avdevice-63` as the only gaps.

So `Copy-ChainOpenCvPackage` (`WindowsPythonApp.Common`) walks the `.pyd`'s import closure. It
searches, in order: the directories `config.py` names, `ONNX_ROOT\bin`, and every `C:\runtime`
directory on `PATH`. Then it rewrites the loader config:

| Where | `BINARIES_PATHS` | Why |
|---|---|---|
| bundle | `LOADER_DIR\bin`, with the closure copied there (54 DLLs), then `..\onnxruntime\capi` | the bundle must not name image paths, and must carry one chain ORT |
| CI venv (`-ReferenceImage`) | the image dirs the closure came from: OpenCV's `bin`, `onnxruntime-source\bin`, `ffmpeg\bin` | nothing to copy; the venv lives inside the image |

`config-3.14.py` points at the copied `.pyd` through `LOADER_DIR` in both cases. Linux keeps
PyPI's opencv-python, which works there.

In a bundle the walk searches the bundle's own `onnxruntime\capi` first (`-SharedDirectory`).
What it finds there is named in `config.py`, not copied. So `opencv_dnn` loads the chain ORT the
app already ships, rather than a second copy in `cv2\bin`. Measured in `:winamd64` on
2026-10-01: `import cv2` alone succeeds before `onnxruntime` is imported, and the bundle went
from 561 to 550 MB.

**G6 prints `UNRESOLVED` for `opencv_dnn`, `opencv_gapi` and `avfilter` on this tree. That
is expected.** They import `onnxruntime.dll`, which lives in `onnxruntime\capi`. G6 models
only the exe directories, not `os.add_dll_directory`, so `Assert-ChainOrtTree -WaiveUnresolved`
reports those findings without failing on them. Every byte verdict stays fatal. The import walk
covers the same edges by name, and the self-test covers them at load time.

## Linux: the closure, and the one library that must not be patched

`python-app-closure.sh` resolves every `DT_NEEDED` against the bundle and then the `--search`
directories (`/opt/gcc-*/lib64` first, for the source-built GCC's `libstdc++`). It skips the
glibc family and the desktop stack (`SYSTEM_SONAMES`), copies what is missing into
`runtime/lib`, and adds an `$ORIGIN`-relative RUNPATH to each user.

**The chain ORT is `--protect`ed: it is never patched.** G6 compares it byte for byte, and
patchelf changes its bytes; the first build proved that (`STALE`/`UNPROVEN`). Its needs go
into `runtime/lib/preload.list` instead. The bundle's `sitecustomize.py` loads that list with
ctypes `RTLD_GLOBAL` before any import, so the sonames are already resident when ORT asks for
them.

`libdnnl.so.3` is passed with `--allow-unresolved`. The image's ORT carries a DNNL provider,
but oneDNN is missing from the image itself, so that provider cannot load anywhere. Nothing
loads it unless DNNL is requested.

### The image's glibc travels

The chain ORT and its Python binding are built against the image's glibc 2.43, newer than
Debian 13's 2.41 and Ubuntu 24.04's 2.39, so a bundle that took the host's glibc loaded on
neither (`GLIBC_2.43 not found`, measured with OrchestrANT 0.0.31 and 0.0.32 on Debian 13).
Since 2026-10-17 `python-app-bundle.sh` runs the family's `bundle-loader.sh --beside` on
`runtime/bin/python3.X`: the interpreter stays there as `python3.X.bin` beside the image's
loader, glibc goes to `runtime/lib/glibc`, and `python3.X` becomes the launcher that
[`linux-build-basics.md`](linux-build-basics.md#linux-packages-that-run-outside-the-image)
describes. It takes the host's glibc when that is as new as the bundled one, so a newer host's
GL drivers keep theirs.

**It sits on the interpreter, not on the `bin/` scripts**, because children start from
`sys.executable`. The bundled loader runs the program with `--argv0` set to the launcher's path,
so `sys.executable` is the launcher and `sys.prefix` stays `runtime/`; a `subprocess` of
`sys.executable`, and `multiprocessing`'s `spawn` and `forkserver` children, all start through
it again. A launcher on the scripts alone would have let every child fall back to the host's
glibc. Measured on himbeere2 (Debian 13, glibc 2.41) with OrchestrANT 0.0.32's arm64 packages
built this way in `:latest` (2026-10-18): the tarball's and the AppImage's
`yolo-monitor --self-test` passed, ONNX Runtime 1.30, OpenCV 5.0 and numpy imported, `spawn` and
`forkserver` children imported ORT through the bundled loader, and `apt-get install --simulate`
took the `.deb`, whose `Depends` is `libc6, libgl1, libglib2.0-0t64, libice6, libsm6, libx11-6,
libxext6`.

## GStreamer

A package's GStreamer is the image's and loads from the package alone; the rule and the four
variables that enforce it are
[`linux-build-basics.md` § GStreamer loads from the package alone](linux-build-basics.md#gstreamer-loads-from-the-package-alone).
An app that starts GStreamer names what it needs in `app.json`:

```json
"gstreamer": {
  "tools": ["gst-launch-1.0"],
  "plugins": ["coreelements", "videoconvertscale", "videorate", "autodetect", "video4linux2"],
  "optional": ["libcamera"],
  "elements": ["autovideosrc", "v4l2src", "videoconvert", "videoscale", "videorate", "capsfilter", "fdsink"]
}
```

`python-app-bundle.sh` then:

- copies the plugins from the image's plugin directories into `runtime/lib/gstreamer-1.0`
  (`gstreamer-bundle.sh copy`; a missing `plugins` entry fails, a missing `optional` one is
  named) and the tools into `runtime/libexec/gstreamer/`;
- lets the closure find the GStreamer and libcamera libraries, which the image reaches only
  through `ld.so.conf`, and puts the bundled loader in front of each tool as in front of the
  interpreter;
- writes those variables into every launcher, unconditionally, with the registry under
  `$XDG_CACHE_HOME/<id>/`, and puts `runtime/libexec/gstreamer` first on `PATH`, so
  `shutil.which("gst-launch-1.0")` finds the bundled tool;
- runs `gstreamer-bundle.sh check` over every `elements` entry, and starts each tool on both
  glibc paths.

A subprocess that builds its own environment must pass the `GST_` variables on; OrchestrANT's
`get_gstreamer_env` does since 2026-10-18.

## Packages

The packagers wrap a finished bundle; they never rebuild it. Each package is then started once,
the way a user would start it, through the same self-test checker the builders use. The
checker also requires ONNX Runtime to load from inside the package.

The lanes run all of this when the consumer has `packaging/app.json`. The hub's
`ci_packaging.sh` and `Invoke-CiPackaging.ps1` build the bundle into `build/app-bundle` after
the wheels and write the packages to `dist/packages`, so the lanes' existing `dist/` artifact
carries them. The 0.5–0.7 GB of loose bundle files stay out of it.

| Package | Built by | Started as |
|---|---|---|
| `<id>-<version>-linux-<x86_64\|aarch64>.tar.gz` | `python-app-package.sh` | unpacked, then `bin/<script>` |
| `<id>_<version>_<amd64\|arm64>.deb` | `python-app-package.sh` | as root: installed with `dpkg -i`, started as `/usr/bin/<script>`, removed again, and `/opt/<id>` must then be gone. Without root (CI's uid 1001), the payload is unpacked with `dpkg-deb -x` instead |
| `<id>-<version>-<x86_64\|aarch64>.AppImage` | `python-app-package.sh` | `APPIMAGE_EXTRACT_AND_RUN=1` (no FUSE in a container), started under a script's name |
| `<id>-<version>-windows-<x64\|arm64>.zip` | `New-PythonAppPackage.ps1` | unpacked, then `<script>.exe`; an arm64 package on its device (below) |
| `<id>-<version>-windows-<x64\|arm64>.msi` | `New-PythonAppPackage.ps1` | inside an elevated Windows container only: installed, the installed `<script>.exe` started, the system `PATH` checked, removed again, and the install folder must then be gone. Anywhere else (a developer's machine), an administrative unpack (`msiexec /a`) proves the payload without touching the machine |
| `<id>-<version>-windows-<x64\|arm64>.msix` + `…-test-signing.cer` | `New-PythonAppPackage.ps1` | unpacked with `makeappx unpack`, then `<script>.exe`. Inside an elevated Windows container, the `.cer` is also trusted for a moment, `signtool verify /pa` must pass, and the root is removed again. Server Core cannot install an MSIX at all |

- **deb:** the bundle goes to `/opt/<id>`, with one `/usr/bin` symlink per script; the
  launchers resolve themselves with `readlink -f`. There is also a desktop file for
  `gui_script` and the icon at its real size.
  Control and payload archives use gzip so older Debian package managers can read them;
  payload entries are root-owned even when the builder runs unprivileged. Archive
  compatibility does not establish runtime compatibility with every host library.
  - `Depends` is computed, not written by hand: the packages (`dpkg -S`) owning every library
    the bundle leaves to the host, and `libc6`, unversioned since the bundle carries its glibc
    (`bundle.json`'s `glibc`; a bundle without it asks for the newest `GLIBC_` any ELF needs). A soname that no installed package provides fails the build. The builder's
    waived sonames (`unresolved_allowed` in `bundle.json`) are skipped.
    Without bundled glibc, a `GLIBC_ABI_DT_RELR` requirement or DT_RELR entries require
    `libc6 (>= 2.36)`; an unknown `GLIBC_ABI_` marker fails the build rather than guessing.
  - `readelf` and `ldconfig` must succeed before the dependency list is accepted; a soname
    whose file has multiple `dpkg -S` owners fails instead of selecting one arbitrarily.
    This check does not establish the target architecture or the loader's selected provider.
    Dynamic entries, their string
    table and version-needs records must also agree with bytes mapped by ELF load segments,
    including split-segment layouts;
    ambiguous mappings or a section-only mismatch fail the build.
  - A bundled dependency only counts as resolved when its ELF class, byte order and machine
    match its importer. An incompatible local file can be skipped by the loader in favor of
    a host library, whose package must then be recorded or cause the scan to fail. These
    identity checks do not prove all architecture-specific loader rules or process scopes.
    A matching-architecture executable or position-independent executable in place of a
    shared library aborts the loader; the scanner fails rather than counting it as bundled.
  - The scanner counts Python site-package preloads as bundled only when the generated
    isolated app and interpreter launchers and `sitecustomize.py` are intact, isolated Python
    confirms the bundled prefix, site and loaded preload paths on both loader paths, and no
    bundled `.pth` file executes an import before `sitecustomize`. A conflicting mapped SONAME
    or directory symlink in the runtime also disables
    the proof because they could hide startup files from the scan. Otherwise it conservatively
    discovers the host library's package, or fails if it has no owner. Passive `.pth` paths
    are accepted. This does not establish non-glibc minimum package versions; see CON188.
  - GPU library-path assumptions also require generated external-path wrappers for all detected
    runnable ELF executables. An unwrapped standalone executable disables that assumption and
    the scanner retains host requirements or fails on unowned libraries. Wrapper coverage
    does not establish all process scopes or inherited legacy RPATH precedence; see CON188.
  - An external or otherwise unproven search directory before a bundled candidate fails discovery
    rather than assuming the candidate wins. A proven Python preload is already mapped; a proven
    GPU launcher path precedes RUNPATH, but an ELF's legacy RPATH precedes that environment path.
    This check does not resolve inherited RPATH or establish the owner of every external path.
  - `Maintainer` comes from `app.json`'s `maintainer`. Without one it is
    `<publisher> <noreply@invalid>`, which says plainly that no address was given.
- **AppImage:** `AppRun` starts `gui_script`. Started through a symlink named after another
  script, it runs that script instead (`$ARGV0`).
- **MSI** (WiX 7, built for 4.0.6, which had no `<Files>` harvesting): `New-PythonAppWxs`
  writes the whole tree out, so every file gets WiX's own component. The same source builds,
  installs and uninstalls under WiX 7 (measured in `:winamd64`, 2026-10-01). The install is per machine into
  `Program Files\<name>`. `msi_upgrade_code` keys a major upgrade, a Start menu shortcut
  points to `gui_script`, and the folder goes on the system `PATH` for the CLIs. The PNG icon
  is wrapped as an `.ico`. Paths that would pass MAX_PATH under `C:\Program Files` are
  refused at build time.
- **MSIX:** `New-PythonAppAppxManifest` writes the manifest. Each script becomes a full-trust
  console app with its own execution alias, which is how the CLIs reach `PATH`. Only
  `gui_script` is listed in Start. `makeappx` packs the bundle where it lies through a mapping
  file, with no staged copy.
  - **Signing:** a test certificate whose subject is the manifest's `CN=<publisher>`. It is
    made in memory (`New-TestSigningCertificate`, `WindowsMsix.Signing`), so no certificate store is touched.
    The unprotected `.pfx` is deleted once `signtool` has signed. The `.cer` ships next to the
    MSIX.
  - **Installing it:** import the `.cer` into *Local Machine → Trusted People* first. It is a
    test signature, not a trusted publisher.
  - Measured in `:winamd64` on 2026-10-01: 240 MB, identity `JonasHeinle.OrchestrANT`
    0.0.29.0, `signtool verify /pa` passes against the shipped `.cer`.
- **Nothing writes into an installed package.** The builders compile all bytecode
  (`uv pip install --compile-bytecode`; a python-build-standalone stdlib and the chain cv2
  separately; the image's stdlib ships compiled), and the launchers pass `-B`. Otherwise an admin's first start leaves
  `__pycache__` behind, which the removal does not delete, and the install folder survives.

**The Linux packages start on older distributions too** (2026-10-17): the image's glibc 2.43
travels with them (above), so the computed `Depends` no longer pins `libc6 (>= 2.43)`. Until then
they needed Ubuntu 26.04 or newer: only 2 of the bundle's 142 ELF files asked for `GLIBC_2.43`,
the chain ORT's `libonnxruntime.so` and its Python binding.

**aarch64 builds the same three packages.** The arm64 image's chain ORT wheel is
`onnxruntime_webgpu`, which the builder takes like the CPU one. Measured under QEMU on
2026-10-01 with the arm64 `:latest`: the closure, G6 and the self-test passed. The tar.gz
(232 MB) and the deb (190 MB, the same `Depends`) each started once. The AppImage cannot be
proven under `qemu-user`, which cannot load the static-PIE `appimagetool`. CI's arm64 lane
runs on a real `ubuntu-26.04-arm` runner, where it builds and starts it.

**Windows arm64 builds the same three packages, cross, in `:winarm64`.** `Invoke-CiPackaging.ps1
-TargetArch arm64` (empty takes the image's `WINDOWS_TARGET_ARCH`) writes the bundle and the
packages to `dist\windows-arm64`:

- **The wheel:** the pure one. The Cython step compiles for the host, so it is skipped, and no
  host venv is synced either, since the bundle never runs the host's dependencies.
- **The runtime:** the image's target CPython (`C:\runtime\python`), laid out by the host
  interpreter of the same source tree with `PC\layout --arch arm64`.
- **The packages:** `uv pip install --target` with `--python-platform aarch64-pc-windows-msvc`,
  from the host. A dependency with no wheel at all (`antlr4-python3-runtime`) is built by the
  host, so a compiled one would carry x64 binaries; the arch gate refuses those.
- A dependency with no wheel for the target but a pure-Python build goes in as that build
  (`-PureBuild`; since 2026-10-16 pyyaml, which has no `cp315` win_arm64 wheel). The host fetches
  its sdist from the URL in `uv.lock` and checks it against the lock's sha256, builds it with the
  package's switch (`PYYAML_FORCE_LIBYAML=0`), refuses anything but one `py3-none-any` wheel without
  a `.pyd`, `.dll`, `.so` or `.exe`, and adds that wheel's own hash to the requirement, so the
  hash-checked install takes it from `--find-links`, with `--only-binary` for that package: given the
  registry's sdist too, uv builds it rather than take the local wheel (OrchestrANT's first run of
  this, 2026-10-16, measured again in `:latest`). Building the sdist the usual way failed:
  uv resolves build requirements for the target platform too, so the x64 host got an arm64 Cython.
- **Excluded from the lock export:** the PyPI ONNX Runtime and OpenCV. PyPI has no win_arm64
  `opencv-python`, so the image's own cv2 (`C:\runtime\python\Lib\site-packages\cv2`) stands in.
- **The launchers:** compiled with `/clang:--target=aarch64-pc-windows-msvc`.
- **The self-test:** nothing on the amd64 host runs an arm64 binary, so the builder copies
  `Test-PythonAppSelfTest.ps1` next to the bundle. The lane's `windows-11-arm` job then starts
  the bundle and the unpacked zip with it (OrchestrANT's `windows-arm64-cross.yml`). The
  packagers build and sign without starting anything.

Measured in `:winarm64` on 2026-10-01 for OrchestrANT 0.0.29:

- The arch gate passed over 191 PE files, and G6 passed.
- That first `:winarm64` (2026-09-22) still carried the NVIDIA stack: its OpenCV was a CUDA
  build, so the packages were zip 902 MB, MSI 793 MB and MSIX 924 MB. The owner decided the
  same day that `:winarm64` has no NVIDIA, which `:winarm64-nvidia` carries instead.
- With the rebuilt `:winarm64` (2026-10-01, hub 19ab55ff), OrchestrANT's CI run 36876194988
  packed zip 204 MB, MSI 167 MB and MSIX 207 MB. The arch gate passed over 166 PE files, and
  `windows-11-arm` started the bundle and the unzipped package, both reporting `ok`.

## Not yet

- **An MSIX install test.** Server Core cannot install an MSIX, so the package is proven
  unpacked and by its signature; an install needs a client Windows host.
- **flatpak.** The bundle needed glibc 2.43 before it carried its own. org.freedesktop.Platform 24.08 shipped an
  older one; 26.08, the image's runtime since 2026-10-07, ships glibc 2.44 (`ldd --version` in
  it), so that blocker is gone. No flatpak of a bundle has been built yet.
- **Size.** OrchestrANT's core dependencies pull in Cython and matplotlib at runtime.
