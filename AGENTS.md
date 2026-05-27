# Kataglyphis-ContainerHub

## Start Here

CRITICAL: For any task that touches Linux image builds, runtime packaging, or publish flows, read these files first with the Read tool:

- `docs/linux-cross-builds.md`
- `docs/linux-build-basics.md`
- `docs/project-info.md`

For runtime helper changes, also read:

- `linux/scripts/01-core/artifact-common.sh`
- `linux/scripts/build-runtime-artifacts.sh`
- `linux/scripts/build-runtime-manifest.sh`

These files document host-specific workarounds that are easy to regress if you improvise.

## Repo Map

- `linux/`: Linux Dockerfiles for base, toolchain, SDK, media, Android, package, Torch, and wrapper images.
- `linux/scripts/`: helper scripts for cross-compiler, SDK artifacts, runtime artifacts, and runtime manifest publishing.
- `docs/`: the canonical build and troubleshooting instructions.
- `windows/`: Windows container images.
- `docs/scripts/sync_versions.py`: keeps the source-controlled version snapshot in `README.md` aligned with the Dockerfiles and setup scripts.

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl` and `ctr` commonly fail here with permission errors.
- Keep the existing QEMU/binfmt multi-platform Linux lane working while extending the additive cross-build lane.
- `linux/scripts/build-cross-compiler.sh` builds one `linux/amd64` compiler image that contains cross toolchains for `amd64`, `arm64`, and `riscv64`. It is not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features just to make foreign-arch builds pass. Foreign-architecture runtime images must keep source-built `clang 22.1.5` and must not fall back to the Ubuntu `clang 22.1.2` packages.
- Preserve the optional runtime payloads and LLVM normalization in `linux/Dockerfile.package`. Do not silently drop the `/usr/local/lib/onnxruntime-*`, LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.

## Verified Runtime Packaging Path On This Host

- Prefer helper scripts over ad hoc `nerdctl build` sequences:
  - `./linux/scripts/build-cross-compiler.sh`
  - `bash linux/scripts/build-runtime-artifacts.sh`
  - `bash linux/scripts/build-runtime-manifest.sh`
- The runtime helpers accept `--target-arches`, `TARGET_ARCHES`, and `TARGET_ARCH` for architecture selection.
- For local foreign-architecture runtime rebuilds, prefer saved OCI layouts under `out/local-oci/android/<arch>`.
- When reusing saved local artifacts, use:
  - `ARTIFACT_CONTEXT_ROOT="$PWD/out/local-oci/android"`
  - `ARTIFACT_CONTEXT_MODE=oci`
  - `RUNTIME_CONTEXT_ROOT="$PWD/out/local-oci/runtime-contexts"`
- The working host workaround is mixed context types: keep `runtime_artifact` as an `oci-layout://...` build context and keep `runtime_base` as a plain rootfs directory context. Do not switch both named contexts to OCI in one build on this host.
- Keep `.dockerignore` excluding `out/local-oci`, `out/local-android-dir`, `out/linux-sdk`, `out/linux-runtime`, and `out/runtime-repair-*` so large exported artifacts do not get sent back as later Docker build contexts.
- Prefer the saved OCI layouts over the plain directory exports in `out/local-android-dir/<arch>`. The plain directory path is much larger and previously dropped runtime payload during OCI-to-directory conversion.

## Push And Publish Rules

- For the runtime helpers, `build-runtime-artifacts.sh --push` should push only the final per-architecture wrapper images.
- `build-runtime-manifest.sh --push` should push those final wrapper images plus the final manifest.
- Use `--push-all` only when the user explicitly wants the `base`, `package`, and `torch` intermediates published too.
- Final cross release target: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
- Final wrapper tags are:
  - `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64`
  - `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64`
  - `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-riscv64`
- Before rebuilding expensive foreign-architecture wrappers, inspect the remote tags with `nerdctl manifest inspect`. If the per-architecture wrapper images already exist remotely, recreate the final manifest directly instead of rebuilding them.
- The direct manifest repair flow is:

```bash
nerdctl manifest rm "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" >/dev/null 2>&1 || true
nerdctl manifest create "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-riscv64"
nerdctl manifest push --purge "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"
nerdctl manifest inspect "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"
```

## Validation

- For runtime verification, check inside a container or inspect raw symlink targets. Do not use `readlink -f` against `out/linux-runtime/*/rootfs`, because absolute symlinks resolve against the host root.
- Confirm all of the following for runtime image validation:
  - `clang --version` reports `22.1.5`
  - the reported target triple matches the architecture
  - `/usr/bin/clang -> /etc/alternatives/clang -> /usr/local/llvm-target/bin/clang`
  - the optional runtime payloads are still present
- Use the checked-in `wrapper-smoke` target documented in `docs/linux-build-basics.md` and `docs/linux-cross-builds.md` for cheaper packaging validation before large publish runs.
- Current automated validation is documentation-focused. Do not claim there is already a single full end-to-end CI workflow that builds every Linux, accelerator, and Windows image variant on each change.

## Host Constraints

- QEMU/binfmt works for `arm64` and `riscv64` on this host.
- Plain local image tags such as `docker.io/library/opencode-local:*` may be treated like remote registry references here. Do not rely on them as reusable `FROM` sources for the runtime packaging chain.
- Disk pressure is common during runtime rebuilds. When free space is tight, build and push one architecture at a time.
- `gh` may be unavailable on this host. Use `nerdctl` and regular git commands unless GitHub CLI is actually installed.

## Documentation Maintenance

- If Dockerfiles or Linux build helpers change, update these docs in the same change:
  - `docs/linux-cross-builds.md`
  - `docs/linux-build-basics.md`
  - `docs/project-info.md`
- If source-controlled version defaults change, run `python3 docs/scripts/sync_versions.py --write`.
- For verification-only checks, run `python3 docs/scripts/sync_versions.py --check`.
