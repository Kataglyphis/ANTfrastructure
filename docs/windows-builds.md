# Windows Build Image

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into five staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.3.3, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.sdk` layers CUDA 12.9 + cuDNN 9.10 GPU SDK.
- `windows/Dockerfile.toolchain` builds CPython 3.14 from source (matching the canonical versions.env).
- `windows/Dockerfile.media` layers GStreamer 1.29.1 (from source via Meson + clang-cl, with optional CUDA support), OpenCV 5.x (source build via CMake+Ninja+clang-cl), ONNX Runtime 1.26.0 (source build via CMake+clang-cl), and ONNX GenAI 0.13.2 (source build via CMake+clang-cl).
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

# Stage 4: media libs (GStreamer, OpenCV, ONNX, GenAI)
nerdctl build --no-cache --progress=plain `
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

## Running the Image

```powershell
nerdctl run --memory 48g -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```
