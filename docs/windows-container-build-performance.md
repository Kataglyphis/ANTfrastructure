# Windows Container Build Performance

Findings from making a large C++23 project build fast inside the Windows
toolchain image. Everything here was **measured**, including the approaches
that failed — the dead ends are documented deliberately so nobody spends an
afternoon rediscovering them.

Reference project: a ~690-object C++23 **modules** engine (Vulkan, CMake +
ninja + clang-cl, Rust bridged in via corrosion/cxx), built on a Dev Drive
host. Concrete script:
`Kataglyphis-BeschleunigerBallett/Scripts/Windows/Build-Windows-Container.ps1`.

## Result

| Approach | Outcome |
| --- | --- |
| **Reusable build container** | ✅ **48 s** no-change, **63 s** one header touched |
| Streaming the build tree in and out | 🟡 ~230 s (worked, but moved ~17 GB per build) |
| sccache with a persistent named volume | ❌ 0.00 % hit rate, 0 bytes stored |
| Named volume mounted as the build directory | ❌ CMake cannot configure inside it |
| Fresh container per build (starting point) | 352–484 s |

## What works: reuse one container

Create a **single long-lived container** instead of one per build. The build
tree never leaves it, so ninja's dependency graph, C++23 module BMIs and
object files are all still there next time.

```powershell
# reuse if running; start if stopped; recreate if the image changed
$state = docker inspect -f '{{.State.Running}}|{{.Image}}' $name 2>$null
```

- **Inbound:** stream sources only. `tar` preserves mtimes, so ninja rebuilds
  exactly what changed.
- **Outbound:** stream back only what the host needs to *run* — `*.exe`,
  `*.dll`, `*.pdb`, `compile_commands.json`, logs. Copying the whole build
  tree back is unnecessary once the container keeps its own copy.

### Safety rails this needs

Reuse trades isolation for speed, so guard it:

1. **Compare the container's image ID against the referenced image** and
   recreate on mismatch — otherwise a rebuilt toolchain image is silently
   ignored and you keep building against the old one.
2. **Provide an explicit reset switch** (`-FreshContainer`, or
   `docker rm -f <name>`). Sources are overwritten in place and never pruned,
   so a file **deleted** on the host still exists inside the container.
3. Keep the build root: if the build script wipes its build directory before
   configuring, gate that behaviour behind an env var (this project uses
   `KATAGLYPHIS_KEEP_BUILD_ROOT`) or reuse buys nothing.

## What does not work

### sccache on a C++23 modules build

`sccache` runs, reports the right cache location, and caches **nothing**:

```
Compile requests            907
Cache hits rate            0.00 %
Cache misses                780
Cache size                    0 bytes
```

Zero stored bytes on a byte-identical tree. Module compilations depend on
BMIs that sccache cannot hash reliably, so results are never stored. A
persistent volume for the cache directory is therefore pointless here —
harmless to leave wired up, but do not expect a speedup. **On non-module
codebases sccache is still worth using**; this finding is specific to C++20/23
modules.

### A named volume as the build directory

Mounting a Docker named volume at the build directory looks like the natural
fix. CMake cannot configure inside one:

```
CMakeTestCXXCompiler.cmake:71 (message)
  ninja: error: loading 'build.ninja': The system cannot find the file specified.
```

Reproduces with a **freshly created** volume, so it is not stale state.
Windows container volumes are filter-driver backed and do not behave like an
ordinary directory for the operations CMake's compiler test performs.

## Gotchas that cost real time

- **Windows path limit inside containers.** Deeply nested paths (here: Rust
  `cxxbridge` output under `cargo/`) fail to extract:

  ```
  ...out/cxxbridge/include/.../native_only.rs:
    Can't create '\\?\C:\ws\...': Invalid argument
  tar: Error exit delayed from previous errors
  ```

  **One such failure aborts the entire tar transfer**, so a single deep path
  silently turns a full transfer into a partial one. Exclude those subtrees.

- **Dev Drive rejects bind mounts.** The filesystem minifilter cannot attach
  ("Der Dateisystem-Minifilter kann nicht an das Entwicklervolume angefügt
  werden"), which forces the tar-pipe transport in the first place. To use
  bind mounts instead, run once elevated and remount:

  ```powershell
  fsutil devdrv setfiltersallowed bindFlt, wcifs
  ```

- **Containers survive successful builds** (`wcifs` teardown lock). A
  lingering container makes it look like a build is still running. Compare the
  newest build-summary timestamp against the container start time before
  assuming, and reap stale containers by name.

- **`docker exec` bypasses the image entrypoint.** When driving a long-lived
  container with `docker exec` (rather than `docker run`), the entrypoint that
  sets up the VS developer environment and the clang-cl ASAN runtime DLL
  directory never runs. Invoke it explicitly:

  ```powershell
  docker exec -w C:\ws $container cmd /S /C C:	emp\scripts\entrypoint.cmd @buildArgs
  ```

  Symptoms if you forget: compilers "not found", or ASAN binaries failing to
  start because `clang_rt.asan*.dll` is not on `PATH`.

- **Mount over a fresh path.** Mounting onto a directory baked into the image
  (e.g. `C:\workspace`) fails at `CreateComputeSystem` when the host OS build
  differs from the image base build. Use a new path such as `C:\ws-mnt`.

## Reusable implementation

The pattern is implemented here so consumers do not copy it:
`windows/scripts/modules/WindowsContainerBuild.Reuse.psm1`
(`Get-ReusableBuildContainer`, `Copy-IntoBuildContainer`,
`Copy-FromBuildContainer`). Import it via the consumer's module resolver.

## Applying this elsewhere

The pattern generalises to any large project built in a Windows container:

1. One reusable container, keyed by name, recreated when the image changes.
2. Sources in, artifacts out — never the intermediate build tree.
3. An explicit "start clean" switch, because reuse means staleness.
4. Exclude deep paths from tar transfers before they abort silently.
