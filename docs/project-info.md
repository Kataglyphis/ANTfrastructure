# Project Information

## Prerequisites

- nerdctl with BuildKit support.
- GPU passthrough configured when building Vulkan-enabled images.

## Installation

1. Clone the repo:

   ```bash
   git clone --recurse-submodules https://github.com/Kataglyphis/Kataglyphis-ContainerHub.git
   ```

## Tests

Current automated validation in this repository is documentation-focused:

- GitHub Actions runs the docs workflow and checks the generated version snapshot with `python3 docs/scripts/sync_versions.py --check`.
- Local container validation is currently documented as targeted smoke builds in `docs/linux-build-basics.md` and `docs/linux-cross-builds.md`.
- The `wrapper-smoke` target in `Dockerfile.package` provides cheap packaging validation before publish.
- `build-cross-chain.sh --verify-chain` performs a dry-run stale-check of the entire cross chain against registry digests without building anything.
- `verify-cross-chain.sh` provides the same staleness check as a standalone script with a lighter footprint. Both use the shared `chain-verify.sh` module.
- `cross_stage_validate_graph()` (in `stage-defs.sh`) runs automatically before every build to check internal stage graph consistency (parent references, cycle detection).
- `build-cross-chain.sh --describe-chain` prints the full stage graph with tag names and parent chains.
- `verify-artifact-copy-parity.sh` checks that the artifact COPY lists in `Dockerfile.package` are consistent.
- `verify-critical-fixes.sh` validates the five critical fixes documented in `AGENTS.md`.
- `build-cross-chain.sh --dry-run` prints all build commands without executing them, useful for auditing the stage transitions.
- There is not yet a single end-to-end CI workflow that builds every Linux, accelerator, and Windows image variant on each change.

## Windows Image Chain

Windows Container builds run on `windows/amd64` only and produce a single published tag (`ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`) on `windows/servercore:ltsc2025`. The lane uses Stevedore's bundled `docker.exe` for both builds and runs (`nerdctl build` has broken DNS in BuildKit on Windows, and `nerdctl run` fails without the Windows CNI `nat` plugin; `docker.exe run --isolation process` works and exposes the host's full CPU count). See `docs/windows-builds.md` for the full build commands and prerequisites.

Stage chain (each `FROM` the previous stage's local tag):

| Stage | Dockerfile | Produces | Contents |
|-------|------------|----------|----------|
| 1 | `windows/Dockerfile.base` | `local/kataglyphis:windows-base` | VS Build Tools 18 (ClangCL toolset), Scoop (LLVM 22, Rust, Flutter, Vulkan SDK, WiX 4), Git, Python bootstrapping, `versions.env` |
| 2 | `docker tag` of base (CPU) **or** `windows/Dockerfile.nvidia` (GPU) | `local/kataglyphis:windows-sdk` | CPU lane simply re-tags `windows-base` (the former `Dockerfile.sdk` no-op shim was removed); GPU lane builds the NVIDIA layer (CUDA 13.3 + cuDNN 9.23 + optional TensorRT 11.1.0.106). `windows/build.ps1 [-Gpu]` picks the variant — both produce the `windows-sdk` tag. |
| 3 | `windows/Dockerfile.toolchain-builder` (+ run+commit) | `local/kataglyphis:windows-toolchain` | CPython 3.14 source-built with ClangCL via `build-toolchain-all.ps1` (`PCbuild\build.bat`) |
| 4 | `windows/Dockerfile.media-merge-builder` (+ per-branch media builders) | `local/kataglyphis:windows-media` | AI/media stack: ONNX Runtime 1.27.0, ONNX GenAI 0.14.0, OpenCV 5.x, LiteRT 2.1.6, LiteRT-LM 0.13.1, TVM 0.25.0, FFmpeg `master` (`--enable-libonnxruntime`; DNN filters ship with the backend, no separate `--enable-dnn`), GStreamer 1.29.2 — all source-built with Ninja/clang-cl in dependency order |
| 5 | `windows/Dockerfile` | `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` | Final developer image (VsDevCmd entrypoint, HEALTHCHECK, smoke-test script) |

Container validation uses `windows/scripts/smoke-test-container.ps1` (18 test categories) and the Docker `HEALTHCHECK` defined in `windows/scripts/healthcheck.ps1`.

The smoke test validates (1) build tools, (2) Python 3.14, (3) Rust, (4) LLVM/Clang+Flutter+WiX, (5) VS Build Tools, (6) Vulkan SDK, (7) CUDA+cuDNN (skippable), (8) ONNX Runtime, (9) ONNX GenAI, (10) OpenCV 5, (11) GStreamer, (12) LiteRT, (13) LiteRT-LM, (14) compiler smoke, (15) CMake+Ninja+clang-cl integration, (16) MSBuild+ClangCL, (17) TVM (source-built), (18) FFmpeg (source-built with DNN/ONNX).

## Roadmap

- Keep the current multi-platform Linux build path working while expanding the amd64-hosted cross artifact lane.
- Improve validation coverage for Linux sequential, cross, NVIDIA, AMD, and runtime packaging flows.
- Continue tightening documentation so the source docs and generated site stay aligned with the Dockerfiles and helper scripts.

## Troubleshooting

### Caching is weird or files cannot be found

**Symptom:** caching is weird or files cannot be found.

**Solution:** If sccache is interfering with builds, unset the wrapper:

```bash
RUSTC_WRAPPER=
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

- `linux/Dockerfile.sdk` forwards the checked-in `LLVM_RELEASE` into the `target-clang` step so that build does not inherit a stale `LLVM_RELEASE` environment variable from an older `cross-compiler-amd64` base image.
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

### Local runtime artifacts: OCI layouts, rootfs, and disk usage

When feeding locally saved runtime artifacts back into later builds:

- Keep `.dockerignore` excluding `out/local-oci`, `out/local-android-dir`, `out/linux-sdk`, `out/linux-runtime`, and `out/runtime-repair-*` so exported OCI layouts and rootfs trees do not get sent back as a later build context.
- Prefer saved OCI layouts such as `out/local-oci/android/<arch>` for foreign-architecture runtime packaging. The plain directory exports under `out/local-android-dir/<arch>` are much larger, and an earlier OCI-to-directory conversion dropped `/usr/local/lib/onnxruntime-cpu`.
- On this host, the verified local runtime path mixes context types: the heavy `runtime_artifact` input comes from an `oci-layout://...` context, while the intermediate `runtime_base` handoff stays a plain rootfs directory because one build still fails when it consumes two named OCI image contexts at once.
- `readlink -f` on symlinks inside `out/linux-runtime/*/rootfs` resolves absolute links against the host root, so use plain `readlink` or validate from inside the built image when checking `/usr/bin/cc`, `/usr/bin/clang`, `/etc/alternatives/cc`, and `/etc/alternatives/clang`.
- Local BuildKit and containerd stores can still grow very large during repeated runtime rebuilds, so prune old images and exported artifacts if disk pressure returns.

### Terminal Freeze or Slowness During Large/Interactive Rebuilds

**Symptom:** Running long interactive `nerdctl build` loops in the foreground causes the terminal to freeze, lag, or experience extremely slow download rates with direct terminal stdout.

**Cause:** High-volume stdout stream pipelines from concurrent `apt` or source fetch downloads (under QEMU/binfmt or native compilation) can overwhelm terminal buffers and choke build execution.

**Solution:** Always build each stage independently and non-interactively in the background using a decoupled session (e.g., `setsid bash -c "nerdctl build ... > stage-build.log 2>&1" & disown`) and poll/inspect progress via file-based `tail`, `grep`, or `pgrep` checks. This guarantees that direct console rendering does not throttle execution threads.

## Contributing

1. Fork the project.
2. Create a feature branch (`git checkout -b feature/my-change`).
3. Make your changes. If modifying build scripts or Dockerfiles, run `python3 docs/scripts/sync_versions.py --check` to verify version consistency.
4. Commit your changes — the pre-commit hook (`.githooks/pre-commit`) runs version-staleness checks and shell syntax validation.
5. Push and open a pull request.

## License

This project's own code is licensed under the **MIT License** — see the
[`LICENSE`](../LICENSE) file at the repository root. Every source file carries a
matching `SPDX-License-Identifier: MIT` header, and the published container
images declare `org.opencontainers.image.licenses="MIT"`.

> Until 2026-08-07 the source headers and two of the three image labels said
> `Apache-2.0` while `LICENSE` said MIT. That contradiction is resolved in
> favour of MIT throughout; nothing about the terms was ever intended to differ
> from `LICENSE`.

Bundled upstream software keeps its own terms — see
[Third-Party Licenses](third-party-licenses.md). Note in particular that
`linux/webserver/dist/assets/NOTICES` is a generated third-party notices bundle:
the licenses in it belong to those projects and are deliberately left untouched.

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
