# windows/downloads — manual, EULA-gated build inputs

Place the **TensorRT** zip here for the GPU lane (`windows/Build-Buildkit.ps1 -Gpu`):

- File: `TensorRT-<TENSORRT_VERSION>.*.zip` (any `*TensorRT*.zip` is picked up;
  with several, the newest by the version in its name — delete the superseded one)
- Version pin: `TENSORRT_VERSION` in `linux/scripts/01-core/versions.env`
- Get it from https://developer.nvidia.com/tensorrt (requires an NVIDIA
  account and EULA acceptance — which is why this cannot be downloaded by the
  build automatically).
- Integrity pin: `TENSORRT_ZIP_SHA256` in versions.env is set, so
  `Install-Tensorrt.ps1` refuses a staged zip whose hash differs. Update it to
  `(Get-FileHash .\TensorRT-*.zip).Hash` together with the zip; a stale hash
  failing the build is intended (`docs/windows-builds.md` § TensorRT setup).

An **empty** directory is fine: the CPU lane never looks here, and the GPU
lane's `Install-Tensorrt.ps1` degrades gracefully (TensorRT EP disabled) when no
zip is present.

Everything in this directory except this README is gitignored. This file is
tracked ONLY so the directory exists in a fresh clone — `windows/Dockerfile.nvidia`
does an unconditional `COPY downloads C:\temp\downloads` that fails when the
directory is missing from the build context.
