# Windows Build Image

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into five staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.3.3, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.sdk` layers CUDA 13.3 + cuDNN 9.23 GPU SDK.
- `windows/Dockerfile.toolchain` builds CPython 3.14 from source (matching the canonical versions.env).
- `windows/Dockerfile.media` layers GStreamer 1.29.1 (from source via Meson + clang-cl, with CUDA auto-detected), OpenCV 5.x (source build via CMake+Ninja+clang-cl, with CUDA auto-detected), ONNX Runtime 1.26.0 (source build with CUDA enabled via CUDA provider), ONNX GenAI 0.13.1 (source build with CUDA enabled), LiteRT 2.1.5 (source build with GPU delegate enabled via Vulkan/OpenCL + external CUDA delegate support), LiteRT-LM 0.13.1 (on-device LLM inference with CUDA support), built in dependency order so each finds the previous.
- `windows/Dockerfile` produces the final developer image from the media image (VsDevCmd entrypoint).

## Prerequisites

Install [Stevedore](https://github.com/slonopotamus/stevedore):

```powershell
# WinGet (recommended)
winget install stevedore

# or Chocolatey
choco install stevedore
```

Reboot after installation. This enables the Windows Containers feature and adds your user to the `docker-users` group.

Stevedore bundles containerd, nerdctl, and Docker Engine for Windows Containers. The build commands below use `nerdctl` (configured through Stevedore's installation at `%ProgramFiles%\Stevedore\bin\nerdctl.exe`).

## Build Commands

Run from the repository root in order:

```powershell
# Stage 1: toolchain base (VS, Scoop, LLVM, Rust)
nerdctl build --no-cache --progress=plain `
  -t local/kataglyphis:windows-base `
  -f windows/Dockerfile.base .

# Stage 2: GPU SDK (CUDA + cuDNN)
nerdctl build --no-cache --progress=plain `
  -t local/kataglyphis:windows-sdk `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-base `
  -f windows/Dockerfile.sdk .

# Stage 3: Python toolchain (CPython 3.14 from source)
nerdctl build --no-cache --progress=plain `
  -t local/kataglyphis:windows-toolchain `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-sdk `
  -f windows/Dockerfile.toolchain .

# Stage 4: media libs (GStreamer, OpenCV, ONNX, GenAI, LiteRT, LiteRT-LM)
# Build order: ONNX -> GenAI -> OpenCV -> LiteRT -> LiteRT-LM -> GStreamer
# NOTE: ONNX Runtime AVX-512+AMX compilation with clang-cl needs ~48 GB RAM.
# Adjust --memory to your host's available resources (--cpu-quota not supported on Windows).
nerdctl build --no-cache --progress=plain --memory 48g `
  -t local/kataglyphis:windows-media `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-toolchain `
  -f windows/Dockerfile.media .

# Stage 5: final developer image
nerdctl build --no-cache --progress=plain `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-media `
  -f windows/Dockerfile .
```

> **Note:** `--progress=plain` is required with nerdctl BuildKit to avoid `write /dev/stdout: The pipe is being closed` errors (see [containerd#10154](https://github.com/containerd/containerd/issues/10154)).

> **Note (.dockerignore):** The repo `.dockerignore` must NOT contain a `windows/` exclusion — the Windows Dockerfiles COPY from the `windows/scripts/` directory within the build context. If `windows/` is added to `.dockerignore`, the COPY steps will fail with "file not found in build context". This exclusion is safe for Linux builds (which use `linux/` context) but breaks Windows builds.

> **Note (nerdctl DNS limitation):** `nerdctl build` has a known DNS limitation on Windows — BuildKit build containers cannot resolve hostnames (`--dns` and `--network host` are not supported on Windows). If builds fail with "Could not resolve host" or "The remote name could not be resolved", use Stevedore's bundled `docker.exe` instead (shares the same containerd backend but has working DNS):
> ```powershell
> # Use Stevedore's docker instead of nerdctl for builds
> "%ProgramFiles%\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache -f windows/Dockerfile.base .
> ```
> See the Common Failure Modes in `AGENTS.md` for full details.

## Stevedore Setup Fixes

After installing Stevedore, the following fixes are required to make `docker.exe` builds work with Windows native containers:

### Fix 1: Exclude Stevedore from Windows Defender

Windows Defender's real-time protection blocks Stevedore's `dockerd.exe` from starting. Add exclusions:

```powershell
Add-MpPreference -ExclusionProcess "dockerd.exe"
Add-MpPreference -ExclusionPath "$env:ProgramFiles\Stevedore"
```

Also exclude the data directories (prevents hcsshim layer commit failures during builds):

```powershell
Add-MpPreference -ExclusionPath "$env:ProgramData\containerd"
Add-MpPreference -ExclusionPath "$env:ProgramData\nerdctl"
```

### Fix 2: Remove stale Docker Desktop daemon.json

If Docker Desktop was previously installed, its daemon config at `C:\ProgramData\docker\config\daemon.json` may specify a hosts pipe (`docker_engine_windows`) that conflicts with Stevedore's `docker_engine` pipe. Remove it:

```powershell
if (Test-Path "C:\ProgramData\docker\config\daemon.json") { Remove-Item "C:\ProgramData\docker\config\daemon.json" }
```

### Fix 3: Change default runtime from hcsshim to runhcs

Stevedore's service defaults to the `com.docker.hcsshim.v1` runtime, but only the `io.containerd.runhcs.v1` shim binary (`containerd-shim-runhcs-v1.exe`) ships with Stevedore. Update the service binary path:

```powershell
sc config stevedore binPath="\"C:\Program Files\Stevedore\dockerd.exe\" --run-service --service-name stevedore --group docker-users --host npipe:////./pipe/dockerDesktopWindowsEngine --host npipe:////./pipe/docker_engine --containerd=npipe:////./pipe/containerd-containerd --default-runtime=io.containerd.runhcs.v1"
```

Then restart:

```powershell
net stop stevedore /y
net start stevedore
```

### Fix 4: Windows Defender exclusions for containerd data

Add exclusions for containerd's snapshot directories (prevents hcsshim layer commit errors — `hcsshim::ActivateLayer failed (0x20)`):

```powershell
Add-MpPreference -ExclusionPath "C:\ProgramData\containerd"
Add-MpPreference -ExclusionPath "C:\ProgramData\nerdctl"
Add-MpPreference -ExclusionPath "C:\temp"
```

### Fix 5: Use docker.exe for builds (not nerdctl)

Always use Stevedore's `docker.exe` for builds — `nerdctl build` lacks DNS resolution:

```powershell
"%ProgramFiles%\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache -t local/kataglyphis:windows-base -f windows/Dockerfile.base .
```

`nerdctl run` works fine for running containers (DNS resolution is only broken during BuildKit builds, not for runs).

## Running the Image

```powershell
nerdctl run --memory 48g -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

## Smoke Testing

After building, run the container smoke test to verify all components:

```powershell
# Run smoke tests inside the built container
nerdctl run --memory 48g -it --rm `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  powershell -File C:\temp\scripts\smoke-test-container.ps1
```

The smoke test validates 16 categories including CUDA Toolkit 13.3, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, and compiler integration.
