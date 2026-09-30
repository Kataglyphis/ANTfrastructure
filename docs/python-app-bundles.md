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
| bundle | `LOADER_DIR\bin`, with the closure copied there (56 DLLs) | the bundle must not name image paths |
| CI venv (`-ReferenceImage`) | the image dirs the closure came from: OpenCV's `bin`, `onnxruntime-source\bin`, `ffmpeg\bin` | nothing to copy; the venv lives inside the image |

`config-3.14.py` points at the copied `.pyd` through `LOADER_DIR` in both cases. Linux keeps
PyPI's opencv-python, which works there.

**G6 prints `UNRESOLVED` for `opencv_dnn`, `opencv_gapi` and `avfilter` on this tree. That
is expected.** They import `onnxruntime.dll`, which sits beside them in `cv2\bin`. G6 models
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

## Not yet

- **Packagers** wrapping the folder: Windows zip, MSI (WiX 4) and MSIX; Linux tar.gz, deb and
  AppImage, each with an install-and-start test.
- **flatpak**, only after measuring the GLIBC symbols the bundle needs against the flatpak
  runtime's older glibc.
- **arm64 on Linux**: the script knows `aarch64`, but it has not been run there.
- **Size.** OrchestrANT's core dependencies pull in Cython and matplotlib at runtime, and on
  Windows the chain ORT ships twice: in `onnxruntime\capi` and in `cv2\bin`.
