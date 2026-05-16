# Windows Build Image

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

```powershell
C:\PATH_TO_NERDCTL\nerdctl.exe build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  -f windows/Dockerfile .
```

> **Note (Windows):** For Windows-based containers and heavy workloads you may need to increase the container memory. Add the `--memory 48g` flag to your `docker run` command, for example:

```powershell
docker run --memory 48g -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

You can also increase memory for buildx builders when creating them, e.g. `docker buildx create --driver docker-container --driver-opt memory=48g --use`.