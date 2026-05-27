# Project Information

## Prerequisites

- Docker with buildx/nerdctl support.
- GPU passthrough configured when building Vulkan-enabled images.

## Installation

1. Clone the repo:

   ```bash
   git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
   ```

## Tests

Current automated validation in this repository is documentation-focused:

- GitHub Actions runs the docs workflow and checks the generated version snapshot with `python docs/scripts/sync_versions.py --check`.
- Local container validation is currently documented as targeted smoke builds in `docs/linux-build-basics.md` and `docs/linux-cross-builds.md`.
- There is not yet a single end-to-end CI workflow that builds every Linux, accelerator, and Windows image variant on each change.

## Roadmap

- Keep the current multi-platform Linux build path working while expanding the amd64-hosted cross artifact lane.
- Improve validation coverage for Linux sequential, cross, NVIDIA, AMD, and runtime packaging flows.
- Continue tightening documentation so the source docs and generated site stay aligned with the Dockerfiles and helper scripts.

## Troubleshooting

### Caching is weird or files cannot be found

**Symptom:** caching is weird or files cannot be found.

**Solution:**

```bash
# change this line
RUSTC_WRAPPER= /usr/bin/sccache 
# to
RUSTC_WRAPPER="" 
```

### No space left on this device

**Symptom:** no space left on this device.

**Solution:**

- Prefer workspace-relative output directories like `logs/` and `out/` for large build artifacts.
- The runtime packaging helpers already avoid `/tmp` by default and use `${XDG_CACHE_HOME:-$HOME/.cache}/opencode/runtime-build-contexts` for temporary local stage handoff.
- The main Linux Dockerfiles also use Dockerfile-specific ignore files so repo-root Linux builds do not keep re-sending `linux/webserver/` through unrelated build contexts.
- Keep exported repair trees such as `out/runtime-repair-*` out of later Docker build contexts too, or routine retries will spend minutes re-uploading them.
- Clean old local images, caches, and exported rootfs artifacts if repeated BuildKit runs fill the disk.

### Local runtime images try to pull from a registry

**Symptom:** a local runtime rebuild tries to resolve `docker.io/library/opencode-local:*` remotely, or `localhost/*` is treated like a real registry and fails with `connect: connection refused`.

**Solution:**

- On this host, do not rely on plain local image tags as reusable `FROM` sources for the runtime packaging chain.
- Keep the helper default local-context handoff for `base -> package -> torch`, and for saved runtime artifact images pass `ARTIFACT_CONTEXT_ROOT=...` with `ARTIFACT_CONTEXT_MODE=oci` instead of expecting `FROM opencode-local:*` to stay local. The helper still runs the Torch stage natively on `linux/<arch>` so the final runtime image includes `/opt/venv`. In cross mode, the media artifact lane now also makes a best-effort `riscv64` app wheelhouse on the amd64 host for the locked `torch`, `torchvision`, and `opencv-python` git-source dependencies used by `Kataglyphis-Orchestr-ANT-ion`, and the native Torch install keeps the upstream `uv.lock` when present so it can reuse those local wheels before falling back to source builds. If a reused cross artifact has an empty `/opt/wheels` the Torch install step now keeps the packages that `uv sync` already resolved instead of trying to install a literal `/opt/wheels/*.whl` glob. The foreign-arch package stage must keep `/usr/bin/clang` wired to the copied target-native `/usr/local/llvm-target/bin/clang` rather than falling back to distro `/usr/local/llvm-22`.
- `docs/linux-cross-builds.md` documents the verified mixed `OCI artifact + plain rootfs base` workaround.

### buildctl or ctr permission denied in rootless troubleshooting

**Symptom:** `buildctl du --verbose` fails with `dial unix /run/buildkit/buildkitd.sock: connect: permission denied`, or `ctr images export` cannot access `/run/containerd/containerd.sock`.

**Solution:**

- Some rootless setups expose `nerdctl` but not the raw BuildKit or containerd sockets.
- Use `nerdctl save`, `nerdctl create`, and `nerdctl export` for local image export and inspection on this host.
- Prefer the checked-in runtime helpers over manual rebuild loops when validating or publishing the cross runtime path.
- Fall back to regular disk usage checks and `nerdctl` cleanup commands when `buildctl` or `ctr` socket access is unavailable.

## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are greatly appreciated.

1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a pull request.

## License

The container images use OCI labels that declare the project license as `MIT`.

## Contact

Jonas Heinle - [@Cataglyphis_](https://twitter.com/Cataglyphis_) - jonasheinle@googlemail.com

Project Link: [https://github.com/Kataglyphis/Kataglyphis-ContainerHub](https://github.com/Kataglyphis/Kataglyphis-ContainerHub)

## Acknowledgements

Thanks for free 3D models:

- [Morgan McGuire, Computer Graphics Archive, July 2017](http://casual-effects.com/data)
- [Viking room](https://sketchfab.com/3d-models/viking-room-a49f1b8e4f5c4ecf9e1fe7d81915ad38)

## Literature

Some very helpful literature, tutorials, etc.

- [Rancher Desktop](https://rancherdesktop.io/)
- [containerd](https://github.com/containerd/containerd)
