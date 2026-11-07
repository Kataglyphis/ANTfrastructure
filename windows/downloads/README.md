# windows/downloads — staged build inputs

The GPU lane (`windows/Build-Buildkit.ps1 -Gpu`) downloads **TensorRT** itself. A zip placed
here wins and saves the ~1.9 GB download:

- File: `TensorRT-<TENSORRT_VERSION>.*.zip` (any `*TensorRT*.zip` is picked up;
  with several, the newest by the version in its name — delete the superseded one)
- Version pin: `TENSORRT_VERSION` in `linux/scripts/01-core/versions.env`
- Get it from https://developer.nvidia.com/tensorrt; `Install-Tensorrt.ps1`
  (`Get-TensorRtZipUrl`) names the URL the lane downloads.
- Integrity pin: `TENSORRT_ZIP_SHA256` in versions.env is set, so
  `Install-Tensorrt.ps1` refuses a staged zip whose hash differs. Update it to
  `(Get-FileHash .\TensorRT-*.zip).Hash` together with the zip; a stale hash
  failing the build is intended (`docs/windows-builds.md` § TensorRT setup).

An **empty** directory is fine: the CPU lane never looks here, and the GPU
lane downloads the pinned zip. It fails when it cannot.

Everything in this directory except this README is gitignored. This file is
tracked ONLY so the directory exists in a fresh clone — `windows/Dockerfile.nvidia`
does an unconditional `COPY downloads C:\temp\downloads` that fails when the
directory is missing from the build context.
