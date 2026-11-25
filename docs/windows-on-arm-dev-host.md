# A Windows-on-Arm laptop as a development host

This page covers an aarch64 laptop (Snapdragon X class) running Windows 11, with the heavy work in WSL2.
Builds for x64 targets run in CI. Here is the local half: what such a device can carry, and how to keep a
build from freezing it.

## What differs from an x64 desktop

- The WSL distro is aarch64. Pull images with `--platform linux/arm64`; an amd64 image would run emulated.
- Memory is unified. The integrated GPU and the NPU draw from the same RAM as Windows and the WSL VM, so a
  model on the NPU and a build in WSL compete for it.
- The CPU has 8 to 12 cores and no SMT. A build on every core leaves the desktop unresponsive.
- WSL containers have no hardware GPU. Vulkan runs on lavapipe, so a GPU test suite is a CPU load.
- A laptop throttles under a long full-core load. Builds take longer than the core count suggests.

## Size WSL2 for it

Follow [§ Sizing the VM for container builds](rancher-desktop-linux-containers.md#sizing-the-vm-for-container-builds).
On a 32 GB, 8-core device that means:

| Setting | Value | Why |
| --- | --- | --- |
| `memory` | `20GB`, or `16GB` while NPU models run on Windows | Windows and the GPU keep the rest |
| `processors` | `7` | one core stays with the desktop |
| `swap` | `8GB` | a buffer for peaks |
| earlyoom | on, preferring compilers and Chrome | kills a build before the VM swaps |
| `RUN_IN_CI_IMAGE_MEMORY`, `RUN_IN_CI_IMAGE_CPUS` | `12g`, `6` | a container at its cap dies alone |

With only an editor open, the VS Code server holds about 2 GB. Each language server adds its own share; an idle
Java pack took 2.8 GB. Uninstall extensions in the WSL remote itself. Settings Sync removes them on the local
side only.

## What to run locally and what to leave to CI

| Job | Here | Why |
| --- | --- | --- |
| An incremental clang build, one crate's tests, the goldens a change touches | yes, one job at a time, capped | fits in 12 GB |
| A full GPU suite on lavapipe | yes, alone, `ctest -j1` | about half an hour on every core |
| A full GCC build | yes, alone, capped, two jobs | a GCC module unit peaks near 4 GB |
| Headless Chrome on SwiftShader drawing a ray tracer | no, CI | took every core and froze the host twice |
| amd64-only images and x64 test binaries | no, CI | they run emulated or not at all |

Check before a heavy job: `free -g` shows at least 6 GB available, `systemctl is-active earlyoom` says
`active`, and no other heavy job holds the lock. One `flock` on one lock file serialises the jobs.

## lavapipe on aarch64

The CI image sets `LP_NATIVE_VECTOR_WIDTH=256`, which lavapipe's acceleration-structure builds need on arm64
([`failure-modes.md`](failure-modes.md#lavapipe-segfaults-building-an-acceleration-structure-on-arm64)). LLVM's
AArch64 JIT aborted wgpu test runs at that width about one run in five, with
`LLVM ERROR: Do not know how to split this operator's operand!`. Run wgpu suites with
`LP_NATIVE_VECTOR_WIDTH=128` on this host, and keep 256 for Vulkan ray tracing.

## After a freeze

A frozen host keeps no WSL logs across the reboot. Look for the run that was active instead:

- `journalctl -u earlyoom` names every process earlyoom killed.
- A container killed at its cap exits 137. Rerun it with fewer jobs, not with a larger cap.
- `ps -eo rss,comm --sort=-rss | head` shows what holds the VM before the next run.
