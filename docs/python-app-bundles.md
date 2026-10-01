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
| Linux (`:latest`) | [`linux/scripts/06-packaging/python-app-bundle.sh`](../linux/scripts/06-packaging/python-app-bundle.sh) | python-build-standalone via `uv python install`, because the image's distro Python is not relocatable |

First consumer: OrchestrANT (`yolo-monitor`, `orchestrant-bench`, `orchestrant-smoke`).
Measured on 2026-09-30/10-01: Windows 561 MB, Linux x86_64 666 MB. Both builders were also
proven by moving the bundle elsewhere and running it again.

## The consumer's side: `packaging/app.json`

```json
{
  "name": "OrchestrANT",
  "id": "orchestrant",
  "distribution": "OrchestrANT",
  "extras": ["app"],
  "chain_opencv": true,
  "scripts": ["yolo-monitor", "orchestrant-bench", "orchestrant-smoke"],
  "data_env": "ORCHESTRANT_DATA_DIR",
  "data_dir": "share/orchestrant",
  "data": [{ "from": "resources/models/yolov26m.onnx", "to": "share/orchestrant/models/yolov26m.onnx" }],
  "self_test": ["yolo-monitor", "--self-test"]
}
```

`name`, `id`, `distribution`, `extras`, `data_env`, `data_dir` and `self_test` are required.
The packagers read `description`, `publisher`, `homepage`, `license_file`, `icon`,
`gui_script` and `msi_upgrade_code`.

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

Both run in the family image, from a built app wheel (`--wheel-dir`, default `dist`):

1. **Runtime.**
   - Windows: `PC\layout --include-stable --include-venv --precompile`, then empty
     `Lib\site-packages`, because the layout copies the image's own packages along with it.
   - Linux: a python-build-standalone of the same version.
2. **Packages.**
   - `uv export --locked --extra <extras>`, then install into the runtime.
   - The app wheel goes in with `--no-deps`; the compiled wheel wins over the pure one.
     On Windows it must carry the runtime's ABI tag (`cp314`, or `abi3`). A `cp314t` wheel
     alone is refused, not swapped for the pure one (`Select-PythonAppWheel`).
   - The PyPI `onnxruntime` is swapped for the chain wheel. See
     [`onnxruntime-single-source.md`](onnxruntime-single-source.md).
3. **Chain OpenCV** (Windows, `"chain_opencv": true`). The next section explains it.
4. **Launchers.**
   - Windows: a small C program per script (`windows/scripts/python/app-launcher/launcher.c`),
     compiled with clang-cl `/MT`. It starts `runtime\python.exe -I` on the entry point and
     passes the arguments, Ctrl+C and the exit code through. A job object makes the child die
     with the launcher.
   - Linux: a shell script in `bin/`.
5. **Data**, copied as `app.json` lists it.
6. **Native closure.**
   - Windows: the VC++ runtime goes beside `python.exe`.
   - Linux: `python-app-closure.sh` copies every missing shared library into `runtime/lib` and
     gives each user an `$ORIGIN` RUNPATH.
7. **Gates**, all fatal:
   - **Import walk** (Windows): `Test-TargetArch.ps1 -ImportWalk -Standalone`. Every DLL that
     any binary imports must be in the bundle or ship with Windows. `-Standalone` makes the
     walk fatal on a native lane, as it is on a cross lane: a bundle has no image `PATH`
     behind it.
   - **G6**: the bundle's ORT is byte-identical to the chain build.
   - **The self-test**, run from the finished bundle.
8. **`bundle.json`**: the wheels, the Python version and the self-test report.

```powershell
# Windows, inside :winamd64
& <hub>\windows\scripts\python\New-PythonAppBundle.ps1 -RepoRoot <repo> -WheelDir dist -OutDir dist\windows-x64\bundle
```

```bash
# Linux, inside :latest
bash <hub>/linux/scripts/06-packaging/python-app-bundle.sh --repo-root <repo> --wheel-dir dist --out-dir dist/linux-x86_64/bundle
```

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
  - `Depends` is computed, not written by hand: `libc6` at the newest `GLIBC_` version any
    bundled ELF asks for, plus the packages (`dpkg -S`) owning every library the bundle leaves
    to the host. A soname that no installed package provides fails the build. The builder's
    waived sonames (`unresolved_allowed` in `bundle.json`) are skipped.
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
    made in memory (`New-PythonAppSigningCertificate`), so no certificate store is touched.
    The unprotected `.pfx` is deleted once `signtool` has signed. The `.cer` ships next to the
    MSIX.
  - **Installing it:** import the `.cer` into *Local Machine → Trusted People* first. It is a
    test signature, not a trusted publisher.
  - Measured in `:winamd64` on 2026-10-01: 240 MB, identity `JonasHeinle.OrchestrANT`
    0.0.29.0, `signtool verify /pa` passes against the shipped `.cer`.
- **Nothing writes into an installed package.** The builders compile all bytecode
  (`uv pip install --compile-bytecode`; python-build-standalone's stdlib and the chain cv2
  separately), and the launchers pass `-B`. Otherwise an admin's first start leaves
  `__pycache__` behind, which the removal does not delete, and the install folder survives.

**The Linux packages need glibc 2.43 (Ubuntu 26.04 or newer).** Measured on 2026-10-01: the
deb's computed `Depends` is `libc6 (>= 2.43), libgl1, libglib2.0-0t64, libice6, libsm6,
libx11-6, libxext6`. Only 2 of the bundle's 142 ELF files ask for `GLIBC_2.43`: the chain
ORT's `libonnxruntime.so` and its Python binding, both built in the Ubuntu 26.04 image. The
next newest need 2.38: GCC 16's `libstdc++` and the closure's `libxcb`. Reaching older
distributions means building the chain ORT against an older glibc, not changing the packager.

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
- With the rebuilt `:winarm64` (2026-10-01, hub 59a4bca3), OrchestrANT's CI run 36876194988
  packed zip 204 MB, MSI 167 MB and MSIX 207 MB. The arch gate passed over 166 PE files, and
  `windows-11-arm` started the bundle and the unzipped package, both reporting `ok`.

## Not yet

- **An MSIX install test.** Server Core cannot install an MSIX, so the package is proven
  unpacked and by its signature; an install needs a client Windows host.
- **flatpak.** The bundle needs glibc 2.43 (above), and org.freedesktop.Platform 24.08 ships
  an older one, so it does not fit that runtime as built.
- **Size.** OrchestrANT's core dependencies pull in Cython and matplotlib at runtime.
