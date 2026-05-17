# Windows Build Image

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

The Windows container build now uses Docker and is split into three staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image.
- `windows/Dockerfile.ai` layers CUDA, ONNX Runtime, and OpenCV on top of that base image.
- `windows/Dockerfile` produces the final developer image from the cached AI image.

```powershell
docker build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t local/kataglyphis:windows-base `
  -f windows/Dockerfile.base .

docker build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t local/kataglyphis:windows-ai `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-base `
  -f windows/Dockerfile.ai .

docker build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-ai `
  -f windows/Dockerfile .
```

Run the commands from the repository root in that order so each later stage can reuse the image tag produced by the previous one.

> **Note (Windows):** For Windows-based containers and heavy workloads you may need to increase the container memory. Add the `--memory 48g` flag to your `docker run` command, for example:

```powershell
docker run --memory 48g -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

You can also increase memory for buildx builders when creating them, e.g. `docker buildx create --driver docker-container --driver-opt memory=48g --use`.