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
- The `wrapper-smoke` target in `Dockerfile.package` provides cheap packaging validation before publish.
- `build-cross-chain.sh --verify-chain` performs a dry-run stale-check of the entire cross chain against registry digests without building anything.
- `build-cross-chain.sh --dry-run` prints all build commands without executing them, useful for auditing the stage transitions.
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
- Keep the helper default local-context handoff for `base -> package -> torch`, and for saved runtime artifact images pass `ARTIFACT_CONTEXT_ROOT=...` with `ARTIFACT_CONTEXT_MODE=oci` instead of expecting `FROM opencode-local:*` to stay local. The helper still runs the Torch stage natively on `linux/<arch>` so the final runtime image includes `/opt/venv`. In cross mode, the media artifact lane now also makes a best-effort `riscv64` app wheelhouse on the amd64 host for the locked `torch`, `torchvision`, and `opencv-python` git-source dependencies used by `Kataglyphis-Orchestr-ANT-ion`, and the native Torch install keeps the upstream `uv.lock` when present so it can reuse those local wheels before falling back to source builds. If a reused cross artifact has an empty `/opt/wheels` the Torch install step now keeps the packages that `uv sync` already resolved instead of trying to install a literal `/opt/wheels/*.whl` glob. The foreign-arch package stage must keep `/usr/bin/clang` wired to the copied target-native `/usr/local/llvm-target/bin/clang` while prioritizing the custom `/opt/gcc-16.1.0` as the default system native compiler, rather than falling back to distro `/usr/local/llvm-22`.
- `docs/linux-cross-builds.md` documents the verified mixed `OCI artifact + plain rootfs base` workaround.

### Rebuilt SDK artifact still reports old clang

**Symptom:** a rebuilt `arm64` or `riscv64` SDK artifact still reports an older `clang` version under `/opt/llvm-target` even though the repository pin was updated.

**Solution:**

- `linux/Dockerfile.sdk` forwards the checked-in `LLVM_RELEASE` into the `target-clang` step so that build does not inherit a stale `LLVM_RELEASE` environment variable from an older `compiler-cross-amd64` base image.
- Rebuild the SDK artifact after updating or selecting the desired compiler base image.

### buildctl or ctr permission denied in rootless troubleshooting

**Symptom:** `buildctl du --verbose` fails with `dial unix /run/buildkit/buildkitd.sock: connect: permission denied`, or `ctr images export` cannot access `/run/containerd/containerd.sock`.

**Solution:**

- Some rootless setups expose `nerdctl` but not the raw BuildKit or containerd sockets.
- Use `nerdctl save`, `nerdctl create`, and `nerdctl export` for local image export and inspection on this host.
- Prefer the checked-in runtime helpers over manual rebuild loops when validating or publishing the cross runtime path.
- Fall back to regular disk usage checks and `nerdctl` cleanup commands when `buildctl` or `ctr` socket access is unavailable.

### Slow build-time downloads in rootless nerdctl/BuildKit

**Symptom:** A `RUN` step that downloads a large source tree is extremely slow. The worst offender is the LLVM `git fetch` in `linux/scripts/02-toolchain/build-clang.sh` (and `linux/scripts/02-toolchain/llvm.sh`) during the cross-compiler/SDK builds.

**Cause:** Rootless BuildKit defaults to `--oci-worker-net=bridge`, so every in-build `git`/`curl`/`wget` is routed through the user-space rootless bridge/slirp path. Registry mirrors do not help here because this is not an image pull.

**Solution (already applied on this host):**

- Switch the rootless BuildKit OCI worker to host networking with a systemd drop-in at `~/.config/systemd/user/buildkit.service.d/override.conf`:

  ```ini
  [Service]
  ExecStart=
  ExecStart="/usr/local/bin/containerd-rootless-setuptool.sh" nsenter -- buildkitd --oci-worker=true --oci-worker-rootless=true --containerd-worker=false --oci-worker-net=host --allow-insecure-entitlement network.host
  ```

- Make rootless containerd networking explicit and fast with `~/.config/systemd/user/containerd.service.d/override.conf`:

  ```ini
  [Service]
  Environment=CONTAINERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns
  Environment=CONTAINERD_ROOTLESS_ROOTLESSKIT_MTU=65520
  Environment=CONTAINERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=true
  Environment=CONTAINERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=builtin
  ```

- Mirror Docker Hub image pulls (only helps `FROM ...`, not in-build downloads) via `~/.config/containerd/certs.d/docker.io/hosts.toml` (referenced by `hosts_dir` in `~/.config/nerdctl/nerdctl.toml`) and `~/.config/buildkit/buildkitd.toml`.

- Apply changes with:

  ```bash
  systemctl --user daemon-reload
  systemctl --user restart containerd buildkit
  ```

- With `--oci-worker-net=host` set, plain `nerdctl build` already uses host networking; you do not need to pass `--network host`.
- For repeated LLVM rebuilds, the host-net change is the main lever. For an even bigger win, cache the LLVM source on the host instead of re-fetching it every build.

### Terminal Freeze or Slowness During Large/Interactive Rebuilds

**Symptom:** Running long interactive `nerdctl build` loops in the foreground causes the terminal to freeze, lag, or experience extremely slow download rates with direct terminal stdout.

**Cause:** High-volume stdout stream pipelines from concurrent `apt` or source fetch downloads (under QEMU/binfmt or native compilation) can overwhelm terminal buffers and choke build execution.

**Solution:** Always build each stage independently and non-interactively in the background using a decoupled session (e.g., `setsid bash -c "nerdctl build ... > stage-build.log 2>&1" & disown`) and poll/inspect progress via file-based `tail`, `grep`, or `pgrep` checks. This guarantees that direct console rendering does not throttle execution threads.

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
